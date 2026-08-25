# SPDX-License-Identifier: MIT
"""A small AXI4-Lite master bus-functional model for cocotb testbenches.

Deliberately minimal: one outstanding transaction, blocking `read`/`write`
coroutines, and explicit response checking.  The point is to make the register
tests read like the host-side API they mirror, so a testbench and a Python
driver exercise the register map the same way.
"""

from __future__ import annotations

import enum

from cocotb.triggers import RisingEdge


class AxiResp(enum.IntEnum):
    """AXI4 response encoding (AMBA AXI4 spec, table A3-4)."""

    OKAY = 0b00
    EXOKAY = 0b01
    SLVERR = 0b10
    DECERR = 0b11


class AxiSlaveError(Exception):
    """Raised when a transaction returns a non-OKAY response and the caller asked us to check."""

    def __init__(self, op: str, addr: int, resp: AxiResp) -> None:
        super().__init__(f"AXI {op} @ 0x{addr:04x} returned {resp.name}")
        self.op = op
        self.addr = addr
        self.resp = resp


class AxiLiteMaster:
    """Drive an AXI4-Lite slave port from a cocotb test.

    Signal names are taken as ``<prefix><channel-signal>``, matching the
    conventional Xilinx/ARM naming used throughout this project.
    """

    def __init__(self, dut, clk, prefix: str = "s_axi_") -> None:
        self.dut = dut
        self.clk = clk
        self._p = prefix

    def _sig(self, name: str):
        return getattr(self.dut, self._p + name)

    async def start(self) -> None:
        """Park every master-driven signal in its idle state."""
        self._sig("awaddr").value = 0
        self._sig("awvalid").value = 0
        self._sig("wdata").value = 0
        self._sig("wstrb").value = 0
        self._sig("wvalid").value = 0
        self._sig("bready").value = 0
        self._sig("araddr").value = 0
        self._sig("arvalid").value = 0
        self._sig("rready").value = 0
        await RisingEdge(self.clk)

    async def write(self, addr: int, data: int, strb: int = 0xF, check: bool = True) -> AxiResp:
        """Issue a single write and return its response.

        Address and data phases are issued together, which is the common case
        for a processor-driven AXI4-Lite port.
        """
        self._sig("awaddr").value = addr
        self._sig("awvalid").value = 1
        self._sig("wdata").value = data
        self._sig("wstrb").value = strb
        self._sig("wvalid").value = 1

        aw_done = False
        w_done = False
        while not (aw_done and w_done):
            await RisingEdge(self.clk)
            if not aw_done and self._sig("awready").value == 1:
                aw_done = True
                self._sig("awvalid").value = 0
            if not w_done and self._sig("wready").value == 1:
                w_done = True
                self._sig("wvalid").value = 0

        self._sig("bready").value = 1
        while True:
            await RisingEdge(self.clk)
            if self._sig("bvalid").value == 1:
                resp = AxiResp(int(self._sig("bresp").value))
                break
        self._sig("bready").value = 0

        if check and resp is not AxiResp.OKAY:
            raise AxiSlaveError("write", addr, resp)
        return resp

    async def read(self, addr: int, check: bool = True) -> tuple[int, AxiResp]:
        """Issue a single read and return ``(data, response)``."""
        self._sig("araddr").value = addr
        self._sig("arvalid").value = 1
        while True:
            await RisingEdge(self.clk)
            if self._sig("arready").value == 1:
                break
        self._sig("arvalid").value = 0

        self._sig("rready").value = 1
        while True:
            await RisingEdge(self.clk)
            if self._sig("rvalid").value == 1:
                data = int(self._sig("rdata").value)
                resp = AxiResp(int(self._sig("rresp").value))
                break
        self._sig("rready").value = 0

        if check and resp is not AxiResp.OKAY:
            raise AxiSlaveError("read", addr, resp)
        return data, resp
