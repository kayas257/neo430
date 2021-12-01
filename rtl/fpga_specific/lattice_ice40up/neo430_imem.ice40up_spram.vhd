-- #################################################################################################
-- #  << NEO430 - Instruction memory ("IMEM") for Lattice ice40 UltraPlus >>                       #
-- # ********************************************************************************************* #
-- # This memory includes the in-place executable image of the application. See the                #
-- # processor's documentary to get more information.                                              #
-- # Note: IMEM is split up into two 8-bit memories - some EDA tools have problems to synthesize   #
-- # a pre-initialized 16-bit memory with byte-enable signals.                                     #
-- # ********************************************************************************************* #
-- # BSD 3-Clause License                                                                          #
-- #                                                                                               #
-- # Copyright (c) 2020, Stephan Nolting. All rights reserved.                                     #
-- #                                                                                               #
-- # Redistribution and use in source and binary forms, with or without modification, are          #
-- # permitted provided that the following conditions are met:                                     #
-- #                                                                                               #
-- # 1. Redistributions of source code must retain the above copyright notice, this list of        #
-- #    conditions and the following disclaimer.                                                   #
-- #                                                                                               #
-- # 2. Redistributions in binary form must reproduce the above copyright notice, this list of     #
-- #    conditions and the following disclaimer in the documentation and/or other materials        #
-- #    provided with the distribution.                                                            #
-- #                                                                                               #
-- # 3. Neither the name of the copyright holder nor the names of its contributors may be used to  #
-- #    endorse or promote products derived from this software without specific prior written      #
-- #    permission.                                                                                #
-- #                                                                                               #
-- # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS   #
-- # OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF               #
-- # MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE    #
-- # COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,     #
-- # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE #
-- # GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED    #
-- # AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING     #
-- # NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED  #
-- # OF THE POSSIBILITY OF SUCH DAMAGE.                                                            #
-- # ********************************************************************************************* #
-- # The NEO430 Processor - https://github.com/stnolting/neo430                                    #
-- #################################################################################################

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neo430;
use neo430.neo430_package.all;
use neo430.neo430_application_image.all; -- this file is generated by the image generator

library iCE40UP;
use iCE40UP.components.all;

entity neo430_imem is
  generic (
    IMEM_SIZE   : natural := 4*1024; -- internal IMEM size in bytes
    IMEM_AS_ROM : boolean := false;  -- implement IMEM as read-only memory?
    BOOTLD_USE  : boolean := true    -- implement and use bootloader?
  );
  port (
    clk_i  : in  std_ulogic; -- global clock line
    rden_i : in  std_ulogic; -- read enable
    wren_i : in  std_ulogic_vector(01 downto 0); -- write enable
    upen_i : in  std_ulogic; -- update enable
    addr_i : in  std_ulogic_vector(15 downto 0); -- address
    data_i : in  std_ulogic_vector(15 downto 0); -- data in
    data_o : out std_ulogic_vector(15 downto 0)  -- data out
  );
end neo430_imem;

architecture neo430_imem_rtl of neo430_imem is

  -- advanced configuration ------------------------------------------------------------------------------------
  constant spram_sleep_mode_en_c : boolean := false; -- put IMEM into sleep mode when idle (for low power)
  -- -------------------------------------------------------------------------------------------------------

  -- ROM types --
  type imem_file8_t is array (0 to IMEM_SIZE/2-1) of std_ulogic_vector(07 downto 0);

  -- init function and split 1x16-bit memory into 2x8-bit memories --
  impure function init_imem(hilo : std_ulogic; init : application_init_image_t) return imem_file8_t is
    variable mem_v : imem_file8_t;
  begin
    for i in 0 to IMEM_SIZE/2-1 loop
      if (hilo = '0') then -- low byte
        mem_v(i) := init(i)(07 downto 00);
      else -- high byte
        mem_v(i) := init(i)(15 downto 08);
      end if;
    end loop; -- i
    return mem_v;
  end function init_imem;

  -- local signals --
  signal acc_en  : std_ulogic;
  signal mem_cs  : std_ulogic;
  signal rdata   : std_ulogic_vector(15 downto 0);
  signal rden    : std_ulogic;
  signal mem_sel : std_ulogic;
  signal addr    : integer;

  -- internal "RAM" type - implemented if bootloader is used and IMEM is RAM and initialized with app code --
  signal imem_file_init_ram_l : imem_file8_t := init_imem('0', application_init_image);
  signal imem_file_init_ram_h : imem_file8_t := init_imem('1', application_init_image);

  -- internal "ROM" type - implemented if bootloader is NOT used; always initialize with app code --
  constant imem_file_rom_l : imem_file8_t := init_imem('0', application_init_image);
  constant imem_file_rom_h : imem_file8_t := init_imem('1', application_init_image);

  -- internal "RAM" type - implemented if bootloader is used and IMEM is RAM --
  signal imem_file_ram_l : imem_file8_t;
  signal imem_file_ram_h : imem_file8_t;

  -- RAM attribute to inhibit bypass-logic - Intel only! --
  attribute ramstyle : string;
  attribute ramstyle of imem_file_init_ram_l : signal is "no_rw_check";
  attribute ramstyle of imem_file_init_ram_h : signal is "no_rw_check";
  attribute ramstyle of imem_file_ram_l : signal is "no_rw_check";
  attribute ramstyle of imem_file_ram_h : signal is "no_rw_check";

  -- RAM attribute to inhibit bypass-logic - Lattice only! --
  attribute syn_ramstyle : string;
  attribute syn_ramstyle of imem_file_init_ram_l : signal is "no_rw_check";
  attribute syn_ramstyle of imem_file_init_ram_h : signal is "no_rw_check";
  attribute syn_ramstyle of imem_file_ram_l : signal is "no_rw_check";
  attribute syn_ramstyle of imem_file_ram_h : signal is "no_rw_check";

  -- SPRAM signals --
  signal spram_clk   : std_logic;
  signal spram_addr  : std_logic_vector(13 downto 0);
  signal spram_di    : std_logic_vector(15 downto 0);
  signal spram_do_lo : std_logic_vector(15 downto 0);
  signal spram_do_hi : std_logic_vector(15 downto 0);
  signal spram_be    : std_logic_vector(03 downto 0);
  signal spram_we    : std_logic;
  signal spram_pwr_n : std_logic;
  signal spram_cs    : std_logic_vector(01 downto 0);

begin

  -- Access Control -----------------------------------------------------------
  -- -----------------------------------------------------------------------------
  acc_en <= '1' when (addr_i >= imem_base_c) and (addr_i < std_ulogic_vector(unsigned(imem_base_c) + IMEM_SIZE)) else '0';
  addr   <= to_integer(unsigned(addr_i(index_size_f(IMEM_SIZE/2) downto 1))); -- word aligned
  mem_cs <= acc_en and (rden_i or wren_i(1) or wren_i(0));


  -- Memory Access ------------------------------------------------------------
  -- -----------------------------------------------------------------------------
  imem_spram_lo_inst : SP256K
  port map (
    AD       => spram_addr,  -- I
    DI       => spram_di,    -- I
    MASKWE   => spram_be,    -- I
    WE       => spram_we,    -- I
    CS       => spram_cs(0), -- I
    CK       => spram_clk,   -- I
    STDBY    => '0',         -- I
    SLEEP    => spram_pwr_n, -- I
    PWROFF_N => '1',         -- I
    DO       => spram_do_lo  -- O
  );

  -- instantiate second SPRAM if IMEM size > 32kB --
  imem_spram_hi_bank:
  if (IMEM_SIZE > 32*1024) generate
    imem_spram_hi_inst : SP256K
    port map (
      AD       => spram_addr,  -- I
      DI       => spram_di,    -- I
      MASKWE   => spram_be,    -- I
      WE       => spram_we,    -- I
      CS       => spram_cs(1), -- I
      CK       => spram_clk,   -- I
      STDBY    => '0',         -- I
      SLEEP    => spram_pwr_n, -- I
      PWROFF_N => '1',         -- I
      DO       => spram_do_hi  -- O
    );
  end generate;

  -- access logic and signal type conversion --
  spram_clk   <= std_logic(clk_i);
  spram_addr  <= std_logic_vector(addr_i(13+1 downto 0+1));
  spram_di    <= std_logic_vector(data_i(15 downto 0));
  spram_we    <= '1' when ((acc_en and upen_i and (wren_i(0) or wren_i(1))) = '1') else '0'; -- global write enable
  rdata       <= std_ulogic_vector(spram_do_lo) when (mem_sel = '0') else std_ulogic_vector(spram_do_hi); -- lo/hi memory bank
  spram_cs(0) <= '1' when (addr_i(15) = '0') else '0'; -- low memory bank
  spram_cs(1) <= '1' when (addr_i(15) = '1') else '0'; -- high memory bank

  spram_be(1 downto 0) <= "11" when (wren_i(0) = '1') else "00"; -- low byte write enable
  spram_be(3 downto 2) <= "11" when (wren_i(1) = '1') else "00"; -- high byte write enable

  spram_pwr_n <= '0' when ((spram_sleep_mode_en_c = false) or (mem_cs = '1')) else '1'; -- LP mode disabled or IMEM selected

  buffer_ff: process(clk_i)
  begin
    -- sanity check --
    if (IMEM_AS_ROM = true) or (BOOTLD_USE = false) then
      assert false report "ICE40 Ultra Plus SPRAM cannot be initialized by bitstream!" severity error;
    end if;
    if (IMEM_SIZE > 48*1024) then
      assert false report "I-mem size out of range! Max 48kB!" severity error;
    end if;
    -- buffer --
    if rising_edge(clk_i) then
      mem_sel <= addr_i(15);
      rden    <= rden_i and acc_en;
    end if;
  end process buffer_ff;

  -- output gate --
  data_o <= rdata when (rden = '1') else (others => '0');


end neo430_imem_rtl;
