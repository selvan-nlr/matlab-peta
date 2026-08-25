# SPDX-License-Identifier: MIT
"""Protocol and behaviour tests for the shared AXI4-Lite register file.

Every other IP in this project inherits its bus behaviour from this block, so
these tests are the platform's foundation: reset values, byte strobes,
read-only semantics, write/read strobes, and out-of-range error reporting.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from zmixsim import AxiLiteMaster, AxiResp

CLK_NS = 10          # 100 MHz
NUM_REGS = 8
RO_FIRST = 4         # registers 4..7 are read-only in the TB wrapper


def reg_addr(index: int) -> int:
    return index * 4


async def setup(dut) -> AxiLiteMaster:
    cocotb.start_soon(Clock(dut.aclk, CLK_NS, unit="ns").start())
    axi = AxiLiteMaster(dut, dut.aclk)
    dut.aresetn.value = 0
    dut.reg_ro_flat.value = 0
    await axi.start()
    await ClockCycles(dut.aclk, 5)
    dut.aresetn.value = 1
    await ClockCycles(dut.aclk, 2)
    return axi


def rw_word(dut, index: int) -> int:
    """Extract register `index` from the flattened reg_rw view."""
    flat = int(dut.reg_rw_flat.value)
    return (flat >> (32 * index)) & 0xFFFF_FFFF


def drive_ro(dut, words: dict[int, int]) -> None:
    """Drive the flattened reg_ro input from a {index: value} mapping.

    Composed locally rather than by read-modify-write of the port: cocotb
    applies writes at the next delta, so successive read-modify-write updates
    within one cycle would silently drop all but the last.
    """
    flat = 0
    for index, value in words.items():
        flat |= (value & 0xFFFF_FFFF) << (32 * index)
    dut.reg_ro_flat.value = flat


@cocotb.test()
async def test_reset_values(dut):
    """Writable registers come out of reset holding their configured constants."""
    axi = await setup(dut)

    data, _ = await axi.read(reg_addr(0))
    assert data == 0xDEADBEEF, f"reg0 reset value was 0x{data:08x}"
    data, _ = await axi.read(reg_addr(1))
    assert data == 0x0000_0001, f"reg1 reset value was 0x{data:08x}"
    data, _ = await axi.read(reg_addr(2))
    assert data == 0, f"reg2 reset value was 0x{data:08x}"

    assert rw_word(dut, 0) == 0xDEADBEEF, "reg_rw output does not reflect the reset value"


@cocotb.test()
async def test_write_read_roundtrip(dut):
    """Each writable register holds what was written, independently of its neighbours."""
    axi = await setup(dut)

    pattern = [0x1234_5678, 0xA5A5_A5A5, 0x0000_00FF, 0xFFFF_FF00]
    for i, value in enumerate(pattern):
        await axi.write(reg_addr(i), value)

    for i, value in enumerate(pattern):
        data, _ = await axi.read(reg_addr(i))
        assert data == value, f"reg{i} read back 0x{data:08x}, expected 0x{value:08x}"
        assert rw_word(dut, i) == value, f"reg_rw({i}) did not follow the bus write"


@cocotb.test()
async def test_byte_strobes(dut):
    """WSTRB masks the update at byte granularity rather than being ignored."""
    axi = await setup(dut)

    await axi.write(reg_addr(2), 0x0000_0000)
    await axi.write(reg_addr(2), 0xAABB_CCDD, strb=0b0010)   # byte 1 only
    data, _ = await axi.read(reg_addr(2))
    assert data == 0x0000_CC00, f"strobed write produced 0x{data:08x}"

    await axi.write(reg_addr(2), 0x1122_3344, strb=0b1001)   # bytes 0 and 3
    data, _ = await axi.read(reg_addr(2))
    assert data == 0x1100_CC44, f"second strobed write produced 0x{data:08x}"


@cocotb.test()
async def test_read_only_registers(dut):
    """Read-only registers mirror reg_ro and refuse to latch bus writes."""
    axi = await setup(dut)

    drive_ro(dut, {RO_FIRST: 0xCAFE_BABE, RO_FIRST + 1: 0x0BAD_F00D})
    await ClockCycles(dut.aclk, 2)

    data, _ = await axi.read(reg_addr(RO_FIRST))
    assert data == 0xCAFE_BABE, f"RO register read 0x{data:08x}"
    data, _ = await axi.read(reg_addr(RO_FIRST + 1))
    assert data == 0x0BAD_F00D, f"RO register read 0x{data:08x}"

    # A write must be accepted on the bus (it is a legal address) but must not
    # change what the register reads back.
    await axi.write(reg_addr(RO_FIRST), 0x0000_0000)
    data, _ = await axi.read(reg_addr(RO_FIRST))
    assert data == 0xCAFE_BABE, "write corrupted a read-only register"


@cocotb.test()
async def test_write_strobe_pulses(dut):
    """wr_stb pulses for exactly one cycle, on the written index only."""
    axi = await setup(dut)

    seen = []

    async def watch():
        while True:
            await RisingEdge(dut.aclk)
            value = int(dut.wr_stb.value)
            if value:
                seen.append(value)

    task = cocotb.start_soon(watch())
    await axi.write(reg_addr(3), 0x5555_5555)
    await ClockCycles(dut.aclk, 4)
    task.cancel()

    assert seen == [1 << 3], f"expected a single wr_stb pulse on bit 3, saw {[hex(v) for v in seen]}"


@cocotb.test()
async def test_read_strobe_pulses(dut):
    """rd_stb pulses once per read, which is what read-to-clear and FIFO pops rely on."""
    axi = await setup(dut)

    seen = []

    async def watch():
        while True:
            await RisingEdge(dut.aclk)
            value = int(dut.rd_stb.value)
            if value:
                seen.append(value)

    task = cocotb.start_soon(watch())
    await axi.read(reg_addr(5))
    await ClockCycles(dut.aclk, 4)
    task.cancel()

    assert seen == [1 << 5], f"expected a single rd_stb pulse on bit 5, saw {[hex(v) for v in seen]}"


@cocotb.test()
async def test_out_of_range_reports_slverr(dut):
    """Addresses beyond the register window error out instead of aliasing."""
    axi = await setup(dut)

    bad = reg_addr(NUM_REGS)          # first word past the end
    resp = await axi.write(bad, 0xFFFF_FFFF, check=False)
    assert resp is AxiResp.SLVERR, f"out-of-range write returned {resp.name}"

    data, resp = await axi.read(bad, check=False)
    assert resp is AxiResp.SLVERR, f"out-of-range read returned {resp.name}"
    assert data == 0, "errored read should not leak register contents"

    far = 0x800
    resp = await axi.write(far, 0x1, check=False)
    assert resp is AxiResp.SLVERR, f"far out-of-range write returned {resp.name}"

    # The block must still work normally afterwards.
    await axi.write(reg_addr(0), 0x0000_0042)
    data, _ = await axi.read(reg_addr(0))
    assert data == 0x42, "register file did not recover after an errored access"


@cocotb.test()
async def test_back_to_back_transactions(dut):
    """Sustained traffic works without a bubble-free assumption or lockup."""
    axi = await setup(dut)

    for i in range(16):
        index = i % RO_FIRST
        value = (0x1000_0000 * (i + 1)) & 0xFFFF_FFFF
        await axi.write(reg_addr(index), value)
        data, _ = await axi.read(reg_addr(index))
        assert data == value, f"iteration {i}: read 0x{data:08x}, expected 0x{value:08x}"
