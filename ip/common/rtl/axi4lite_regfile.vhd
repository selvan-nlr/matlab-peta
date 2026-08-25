-- SPDX-License-Identifier: MIT
--
-- axi4lite_regfile -- the one and only AXI4-Lite slave in this project.
--
-- Rationale
-- ---------
-- Every custom IP here presents a plain register interface (reg_rw / reg_ro /
-- wr_stb / rd_stb) and *never* implements its own bus handshaking.  One bus
-- adapter, verified once, removes an entire class of copy-paste AXI bugs and
-- keeps the IP testbenches focused on behaviour instead of protocol.
--
-- Behaviour
-- ---------
--   * Word-addressed: register index = addr(clog2(NUM_REGS)+1 downto 2).
--   * RO_MASK(i) = '1' -> reads return reg_ro(i); writes to it do not change
--     reg_rw(i), but wr_stb(i) still pulses so an IP can use a read-only
--     address as a write-triggered command port.
--   * wr_stb(i) / rd_stb(i) are single-cycle pulses aligned with the cycle in
--     which the access is committed.  rd_stb is the hook for read-to-clear
--     status bits and for FIFO pop semantics.
--   * Out-of-range addresses complete with SLVERR rather than aliasing, so a
--     host-side API bug surfaces as an error instead of silent corruption.
--   * No outstanding transactions: at most one write and one read in flight.
--     AXI4-Lite permits this and it keeps the proof obligations small.
--
-- Language level: VHDL-2008.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.zmix_pkg.all;

entity axi4lite_regfile is
  generic (
    -- Number of 32-bit registers exposed by this instance.
    NUM_REGS   : positive := 8;
    -- Byte-address width of the AXI4-Lite slave port.
    ADDR_W     : positive := 12;
    -- '1' => register i is read-only from the bus (reads come from reg_ro).
    RO_MASK    : std_logic_vector;
    -- Power-on contents of the writable registers.
    RESET_VALS : slv32_array_t
  );
  port (
    aclk    : in    std_logic;
    aresetn : in    std_logic;

    -- AXI4-Lite slave -------------------------------------------------------
    s_axi_awaddr  : in    std_logic_vector(ADDR_W - 1 downto 0);
    s_axi_awprot  : in    std_logic_vector(2 downto 0);
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
    s_axi_arprot  : in    std_logic_vector(2 downto 0);
    s_axi_arvalid : in    std_logic;
    s_axi_arready : out   std_logic;

    s_axi_rdata   : out   std_logic_vector(31 downto 0);
    s_axi_rresp   : out   std_logic_vector(1 downto 0);
    s_axi_rvalid  : out   std_logic;
    s_axi_rready  : in    std_logic;

    -- Register interface presented to the owning IP -------------------------
    reg_rw  : out   slv32_array_t(0 to NUM_REGS - 1);
    reg_ro  : in    slv32_array_t(0 to NUM_REGS - 1);
    wr_stb  : out   std_logic_vector(NUM_REGS - 1 downto 0);
    rd_stb  : out   std_logic_vector(NUM_REGS - 1 downto 0)
  );
end entity axi4lite_regfile;

architecture rtl of axi4lite_regfile is

  constant IDX_W    : positive := clog2(NUM_REGS);
  constant ADDR_LSB : natural  := 2;                    -- 32-bit words

  signal regs : slv32_array_t(0 to NUM_REGS - 1);

  -- Write channel bookkeeping.
  signal aw_captured : std_logic;
  signal w_captured  : std_logic;
  signal awaddr_q    : std_logic_vector(ADDR_W - 1 downto 0);
  signal wdata_q     : std_logic_vector(31 downto 0);
  signal wstrb_q     : std_logic_vector(3 downto 0);
  signal awready_i   : std_logic;
  signal wready_i    : std_logic;
  signal bvalid_i    : std_logic;

  -- Read channel bookkeeping.
  signal araddr_q    : std_logic_vector(ADDR_W - 1 downto 0);
  signal ar_captured : std_logic;
  signal arready_i   : std_logic;
  signal rvalid_i    : std_logic;

  -- Decode a byte address into a register index plus an in-range flag.
  function addr_index (addr : std_logic_vector) return natural is
    variable idx : natural;
  begin
    idx := to_integer(unsigned(addr(ADDR_LSB + IDX_W - 1 downto ADDR_LSB)));
    return idx;
  end function addr_index;

  function addr_in_range (addr : std_logic_vector) return boolean is
    variable hi : natural := 0;
  begin
    -- Any address bit above the register window must be zero, otherwise the
    -- access belongs to a neighbouring block and must not alias into ours.
    if ADDR_W > ADDR_LSB + IDX_W then
      if unsigned(addr(ADDR_W - 1 downto ADDR_LSB + IDX_W)) /= 0 then
        return false;
      end if;
    end if;
    return addr_index(addr) < NUM_REGS;
  end function addr_in_range;

begin

  -- Compile-time sanity: the generics must agree with NUM_REGS.
  assert RO_MASK'length = NUM_REGS
    report "axi4lite_regfile: RO_MASK length must equal NUM_REGS"
    severity failure;
  assert RESET_VALS'length = NUM_REGS
    report "axi4lite_regfile: RESET_VALS length must equal NUM_REGS"
    severity failure;
  assert ADDR_W >= ADDR_LSB + IDX_W
    report "axi4lite_regfile: ADDR_W too small for NUM_REGS"
    severity failure;

  s_axi_awready <= awready_i;
  s_axi_wready  <= wready_i;
  s_axi_bvalid  <= bvalid_i;
  s_axi_arready <= arready_i;
  s_axi_rvalid  <= rvalid_i;
  reg_rw        <= regs;

  -- Write path -------------------------------------------------------------
  write_proc : process (aclk) is
    variable idx : natural;
  begin

    if rising_edge(aclk) then
      wr_stb <= (others => '0');

      if aresetn = '0' then
        awready_i   <= '1';
        wready_i    <= '1';
        bvalid_i    <= '0';
        s_axi_bresp <= AXI_RESP_OKAY;
        aw_captured <= '0';
        w_captured  <= '0';

        for i in regs'range loop
          regs(i) <= RESET_VALS(RESET_VALS'low + i);
        end loop;

      else
        if s_axi_awvalid = '1' and awready_i = '1' then
          awaddr_q    <= s_axi_awaddr;
          aw_captured <= '1';
          awready_i   <= '0';
        end if;

        if s_axi_wvalid = '1' and wready_i = '1' then
          wdata_q    <= s_axi_wdata;
          wstrb_q    <= s_axi_wstrb;
          w_captured <= '1';
          wready_i   <= '0';
        end if;

        -- Commit once both halves of the write have landed.
        if aw_captured = '1' and w_captured = '1' and bvalid_i = '0' then
          if addr_in_range(awaddr_q) then
            idx         := addr_index(awaddr_q);
            wr_stb(idx) <= '1';
            s_axi_bresp <= AXI_RESP_OKAY;

            if RO_MASK(RO_MASK'low + idx) = '0' then
              for b in 0 to 3 loop
                if wstrb_q(b) = '1' then
                  regs(idx)(8 * b + 7 downto 8 * b) <= wdata_q(8 * b + 7 downto 8 * b);
                end if;
              end loop;
            end if;
          else
            s_axi_bresp <= AXI_RESP_SLVERR;
          end if;

          bvalid_i <= '1';
        end if;

        if bvalid_i = '1' and s_axi_bready = '1' then
          bvalid_i    <= '0';
          aw_captured <= '0';
          w_captured  <= '0';
          awready_i   <= '1';
          wready_i    <= '1';
        end if;
      end if;
    end if;

  end process write_proc;

  -- Read path --------------------------------------------------------------
  read_proc : process (aclk) is
    variable idx : natural;
  begin

    if rising_edge(aclk) then
      rd_stb <= (others => '0');

      if aresetn = '0' then
        arready_i   <= '1';
        rvalid_i    <= '0';
        ar_captured <= '0';
        s_axi_rdata <= (others => '0');
        s_axi_rresp <= AXI_RESP_OKAY;

      else
        if s_axi_arvalid = '1' and arready_i = '1' then
          araddr_q    <= s_axi_araddr;
          ar_captured <= '1';
          arready_i   <= '0';
        end if;

        if ar_captured = '1' and rvalid_i = '0' then
          if addr_in_range(araddr_q) then
            idx         := addr_index(araddr_q);
            rd_stb(idx) <= '1';
            s_axi_rresp <= AXI_RESP_OKAY;

            if RO_MASK(RO_MASK'low + idx) = '1' then
              s_axi_rdata <= reg_ro(idx);
            else
              s_axi_rdata <= regs(idx);
            end if;
          else
            s_axi_rdata <= (others => '0');
            s_axi_rresp <= AXI_RESP_SLVERR;
          end if;

          rvalid_i    <= '1';
          ar_captured <= '0';
        end if;

        if rvalid_i = '1' and s_axi_rready = '1' then
          rvalid_i  <= '0';
          arready_i <= '1';
        end if;
      end if;
    end if;

  end process read_proc;

end architecture rtl;
