-- SPDX-License-Identifier: MIT
--
-- zmix_pkg -- shared types and helper functions for the ZedBoard mixed-signal
-- platform.  Kept deliberately small: anything that grows a personality of its
-- own belongs in its own entity, not in a grab-bag package.
--
-- Language level: VHDL-2008 (unconstrained array types in ports and generics).

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

package zmix_pkg is

  -- Register-file payloads.  Every IP in this project speaks 32-bit words on
  -- AXI4-Lite, so one array type covers the whole platform.
  type slv32_array_t is array (natural range <>) of std_logic_vector(31 downto 0);

  -- Ceiling log2, clamped to at least 1 so that a single-element address bus is
  -- still a legal (1 downto 0)-style slice rather than a null range.
  function clog2(n : positive) return positive;

  -- Reset-value helper: an all-zero constant of the right length, for register
  -- files that do not care about their power-on contents.
  function zeros(n : positive) return slv32_array_t;

  -- AXI4-Lite response encodings (AMBA AXI4 spec, table A3-4).
  constant AXI_RESP_OKAY   : std_logic_vector(1 downto 0) := "00";
  constant AXI_RESP_SLVERR : std_logic_vector(1 downto 0) := "10";
  constant AXI_RESP_DECERR : std_logic_vector(1 downto 0) := "11";

end package zmix_pkg;

package body zmix_pkg is

  function clog2(n : positive) return positive is
    variable acc : natural  := 1;
    variable res : positive := 1;
  begin
    -- Smallest res such that 2**res >= n, with a floor of 1.
    while acc < n loop
      acc := acc * 2;
      exit when acc >= n;
      res := res + 1;
    end loop;
    return res;
  end function clog2;

  function zeros(n : positive) return slv32_array_t is
    variable res : slv32_array_t(0 to n - 1) := (others => (others => '0'));
  begin
    return res;
  end function zeros;

end package body zmix_pkg;
