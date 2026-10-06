# ZMIX — ZedBoard mixed-signal platform

A from-scratch **VHDL** platform for the Digilent ZedBoard (Xilinx Zynq-7020) that makes a set of
custom IP cores readable and writable from a host over Ethernet:

1. **ADC** — sample a Digilent PmodAD1 (2 × AD7476A, 12-bit) on PMOD JA and expose the samples as registers.
2. **DAC** — write registers that drive a PmodDA2 (DAC121S101, 12-bit) or PmodDA3 (AD5541A, 16-bit).
3. **OLED** — display user-defined text plus live ADC and DAC values on an SSD1306/SSD1331 panel.

Around that sit the things that turn a demo into a platform: a single generated register map, per-IP
cocotb testbenches that run on free tools, scriptable builds, and a layered host API.

> Design lineage: the engineering practices here — one register map generated into every language,
> per-IP testbenches with a `SUCCESS` marker convention, a host-only CI lane that needs no FPGA
> toolchain, and a network daemon fronting a `/dev/mem` register window — are adapted from
> [PulsePins](https://github.com/rokzitko/PulsePins) (MIT, Rok Žitko), which does the same job on an
> Intel DE10-Nano in SystemVerilog. None of its code is reused; the ideas are.

## Status

| Piece | State |
| ----- | ----- |
| Shared AXI4-Lite register file (`ip/common`) | **done**, 8/8 cocotb tests passing |
| Register-map generator (YAML → VHDL/C/Python/Markdown) | **done**, 4 blocks / 25 registers |
| `sysid` bitstream identification | register map defined |
| `adc_ad7476` sampling front end | register map defined |
| `dac_spi` output stage | register map defined |
| `oled_ctrl` text display | register map defined |
| Vivado build scripts, constraints, top level | planned |
| Host API + four control-plane variants | planned |

## The one idea worth copying

**Nothing describes a register twice.** `regmap/*.yaml` is the only place a register, field, offset or
reset value is written down. `scripts/gen_regmap.py` turns it into:

* `ip/<block>/rtl/<block>_regs_pkg.vhd` — VHDL constants, field slices, `RO_MASK`, `RESET_VALS`
* `sw/include/zmix/<block>_regs.h` — C offsets, shifts and masks
* `sw/host/zmix/regs/<block>.py` — Python model with field pack/unpack
* `docs/registers/<block>.md` — the documentation table

`make regmap-check` fails the build if any of them is stale, so RTL and host software cannot drift
apart. Adding a register is a four-line YAML edit, not a five-file refactor.

The second idea: **exactly one AXI4-Lite slave exists in the whole project**
(`ip/common/rtl/axi4lite_regfile.vhd`). Every IP presents a plain `reg_rw` / `reg_ro` / `wr_stb` /
`rd_stb` interface and never touches the bus. That removes a whole class of copy-pasted protocol
bugs and keeps IP testbenches focused on behaviour.

## Four control planes, one design

The host link is the part of a project like this that people most often want to do differently, so it
is a swappable layer rather than a fork. The PL side is identical in all four (except C, which adds a
PL-side network stack); only the software and the top level change.

| Variant | Host link | Where the register access happens |
| ------- | --------- | --------------------------------- |
| **A** `ps-linux-scpi` | Linux on the Zynq PS, SCPI-style line protocol on TCP 5025 | C++ daemon, `/dev/mem` or UIO window onto AXI4-Lite |
| **B** `ps-baremetal` | Standalone Cortex-A9 app with lwIP | direct pointer writes, no OS |
| **C** `pl-only-udp` | VHDL UDP/IP stack in the PL, no PS involvement | a register-bus master built in fabric |
| **D** `ps-rest` | Linux, HTTP/JSON API plus a browser dashboard | same daemon core as A, different front end |

Variant A is the recommended default: it gives you PyVISA, plain sockets, Jupyter and `scp` for free.

## Layout

```
regmap/          register descriptions (the source of truth) + platform address map
ip/common/       shared VHDL: AXI4-Lite register file, types, primitives
ip/<block>/      rtl/ + tb/ + doc/ per custom IP
net/             PL-side UDP/IP stack (variant C)
top/             top level and per-variant wrappers
constraints/     ZedBoard XDC
scripts/         register generator, Vivado build scripts, CI helpers
sim/             cocotb BFMs and shared test helpers
sw/host/         host-side Python API (stdlib only)
sw/variant_*/    the four control-plane implementations
docs/            architecture notes and generated register documentation
```

## Getting started (no board, no Vivado)

Everything below runs on a laptop with free tools:

```bash
sudo apt-get install -y ghdl
python3 -m pip install cocotb pyyaml pytest

make regmap        # regenerate VHDL/C/Python/docs from the YAML
make test          # run every IP testbench under GHDL
make check         # what CI runs
```

Run one testbench with waveforms:

```bash
make -C ip/common/tb WAVES=1
gtkwave ip/common/tb/tb_axi4lite_regfile.ghw
```

## Documentation

* [Architecture](docs/architecture.md) — how the pieces fit, and why
* [OPNT control stack (draft)](docs/opnt_control_stack_architecture.md) — RFSoC/OPNT architecture inspired by QubitControlStack
* [Platform address map](docs/registers/index.md) — generated
* [`sysid`](docs/registers/sysid.md) · [`adc_ad7476`](docs/registers/adc_ad7476.md) · [`dac_spi`](docs/registers/dac_spi.md) · [`oled_ctrl`](docs/registers/oled_ctrl.md)

## Licence

MIT.
