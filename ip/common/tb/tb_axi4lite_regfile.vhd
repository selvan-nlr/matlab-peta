-- SPDX-License-Identifier: MIT
--
-- Simulation wrapper for axi4lite_regfile.
--
-- cocotb drives VHDL through VPI, where arrays of std_logic_vector are awkward
-- to reach portably.  This wrapper pins the generics to a known configuration
-- and flattens the register arrays into plain vectors so the Python testbench
-- can poke reg_ro and observe reg_rw directly.
--
-- Configuration under test: 8 registers, indices 4..7 read-only.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.zmix_pkg.all;

entity tb_axi4lite_regfile is
  generic (
    NUM_REGS : positive := 8;
    ADDR_W   : positive := 12
  );
  port (
    aclk    : in    std_logic;
    aresetn : in    std_logic;

    s_axi_awaddr  : in    std_logic_vector(ADDR_W - 1 downto 0);
    s_axi_awvalid : in    std_logic;
    s_axi_awready : out   std_logic;
    s_axi_wdata   : in    std_logic_vector(31 downto 0);
    s_axi_wstrb   : in    std_logic_vector(3 downto 0);
    s_axi_wvalid  : in    std_logic;
    s_axi_wready  : out   std_logic;
    s_axi_bresp   : out   std_logic_vector(1 downto 0);
    s_axi_bvalid  : out   std_logic;
    s_axi_bready  : in    std_logic;
    s_axi_araddr  : in    std_logic_vector(ADDR_W - 1 downto 0);
    s_axi_arvalid : in    std_logic;
    s_axi_arready : out   std_logic;
    s_axi_rdata   : out   std_logic_vector(31 downto 0);
    s_axi_rresp   : out   std_logic_vector(1 downto 0);
    s_axi_rvalid  : out   std_logic;
    s_axi_rready  : in    std_logic;

    -- Flattened register views, register i occupying bits 32*i+31 downto 32*i.
    reg_rw_flat : out   std_logic_vector(32 * NUM_REGS - 1 downto 0);
    reg_ro_flat : in    std_logic_vector(32 * NUM_REGS - 1 downto 0);
    wr_stb      : out   std_logic_vector(NUM_REGS - 1 downto 0);
    rd_stb      : out   std_logic_vector(NUM_REGS - 1 downto 0)
  );
end entity tb_axi4lite_regfile;

architecture sim of tb_axi4lite_regfile is

  -- Registers 4..7 are read-only; 0..3 are writable.
  constant RO_MASK_C    : std_logic_vector(NUM_REGS - 1 downto 0) := "11110000";
  constant RESET_VALS_C : slv32_array_t(0 to NUM_REGS - 1) :=
  (
    0 => x"DEADBEEF",
    1 => x"00000001",
    others => (others => '0')
  );

  signal reg_rw : slv32_array_t(0 to NUM_REGS - 1);
  signal reg_ro : slv32_array_t(0 to NUM_REGS - 1);

begin

  flatten : for i in 0 to NUM_REGS - 1 generate
    reg_rw_flat(32 * i + 31 downto 32 * i) <= reg_rw(i);
    reg_ro(i)                              <= reg_ro_flat(32 * i + 31 downto 32 * i);
  end generate flatten;

  dut : entity work.axi4lite_regfile
    generic map (
      NUM_REGS   => NUM_REGS,
      ADDR_W     => ADDR_W,
      RO_MASK    => RO_MASK_C,
      RESET_VALS => RESET_VALS_C
    )
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      s_axi_awaddr  => s_axi_awaddr,
      s_axi_awprot  => (others => '0'),
      s_axi_awvalid => s_axi_awvalid,
      s_axi_awready => s_axi_awready,
      s_axi_wdata   => s_axi_wdata,
      s_axi_wstrb   => s_axi_wstrb,
      s_axi_wvalid  => s_axi_wvalid,
      s_axi_wready  => s_axi_wready,
      s_axi_bresp   => s_axi_bresp,
      s_axi_bvalid  => s_axi_bvalid,
      s_axi_bready  => s_axi_bready,
      s_axi_araddr  => s_axi_araddr,
      s_axi_arprot  => (others => '0'),
      s_axi_arvalid => s_axi_arvalid,
      s_axi_arready => s_axi_arready,
      s_axi_rdata   => s_axi_rdata,
      s_axi_rresp   => s_axi_rresp,
      s_axi_rvalid  => s_axi_rvalid,
      s_axi_rready  => s_axi_rready,
      reg_rw        => reg_rw,
      reg_ro        => reg_ro,
      wr_stb        => wr_stb,
      rd_stb        => rd_stb
    );

end architecture sim;
