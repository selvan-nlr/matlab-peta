# Architecture

## Goal

Make a set of custom VHDL IP cores on a ZedBoard readable and writable from a host over Ethernet,
with an ADC front end, a DAC output stage, and an OLED that shows user text alongside live converter
values — and do it so that the register map, the RTL, the testbenches and the host API cannot drift
apart.

## The register-map contract

Everything hangs off `regmap/*.yaml`. A block description looks like this:

```yaml
block: dac_spi
registers:
  - name: CTRL
    offset: 0x00
    access: rw
    fields:
      - {name: ENABLE, bits: "0", description: Enable the serial engine.}
      - {name: LOAD,   bits: "1", description: "Self-clearing: shift DATA out now."}
```

`scripts/gen_regmap.py` expands that into VHDL constants, a C header, a Python model and a docs
table. `make regmap-check` diffs the generated files against the YAML and fails if they are stale,
so a register added in RTL but not in the driver is a red build, not a mystery on the bench.

Two conventions make the generated VHDL directly usable:

* **Register index = byte offset / 4.** Address gaps are filled with generated `RESERVED_xx` entries
  so no lookup table is needed anywhere.
* **`RO_MASK` and `RESET_VALS` are generated constants** passed straight into the shared register
  file, so "which registers are read-only" is answered in the YAML and nowhere else.

## Bus layer

```
        AXI4-Lite                     plain signals
 PS ───────────────►  axi4lite_regfile  ─────────────►  IP logic
                       (one instance          reg_rw / reg_ro
                        per IP block)         wr_stb / rd_stb
```

`ip/common/rtl/axi4lite_regfile.vhd` is the only AXI slave in the project. It handles the
handshaking, byte strobes, read-only registers and out-of-range decoding; the IP behind it sees a
register array and two strobe vectors.

Design decisions worth knowing:

* **Out-of-range accesses return `SLVERR`**, not a silent alias. A host-side address bug surfaces as
  an exception instead of corrupting a neighbouring register.
* **`wr_stb` fires even for read-only addresses.** That makes a read-only register usable as a
  write-triggered command port, which is how `CTRL.TRIG`-style self-clearing bits are built.
* **`rd_stb` fires on every read.** This is the hook for read-to-clear status bits and for FIFO pop
  semantics — the ADC's `DATA` register pops one sample per read using exactly this.
* **One outstanding transaction.** AXI4-Lite permits it and it keeps the block small enough to
  reason about completely.

## IP blocks

### `sysid`

Reads back a magic word, the register-map ABI version, the git SHA and build timestamp baked into
the bitstream, and a capability word saying which optional blocks are present. The host API reads
this first and refuses to continue on a major-version mismatch. This is cheap and it removes the
"driver is talking to yesterday's bitstream" class of bug entirely.

### `adc_ad7476`

The PmodAD1 carries two AD7476A converters that share `SCLK` and `CS` and each drive their own data
line, so both channels are captured simultaneously — there is no channel mux, and the register map
reflects that with a single `DATA` word holding both results.

The engine supports single-shot (`CTRL.TRIG`), free-running (`CTRL.CONTINUOUS` at `RATE_DIV`) and
externally triggered conversion. Samples go into a small FIFO so a host on the far end of a network
can burst-read without racing the converter, while `LAST` keeps the most recent pair readable
non-destructively for display refresh and slow polling.

### `dac_spi`

One serial engine covering PmodDA2 (two 12-bit DAC121S101) and PmodDA3 (16-bit AD5541A with an
`LDAC` strobe), selected at runtime by `CFG.DEVICE` rather than at build time. `READBACK` reports
the frame the engine actually shifted out, which is deliberately distinct from the staged `DATA0`
value: it lets the host distinguish "value staged" from "value delivered" when an output looks wrong.

### `oled_ctrl`

Hybrid ownership, which is the arrangement that survives contact with reality:

* **The PL owns the panel.** It runs the power-on sequence, holds a character framebuffer in block
  RAM and refreshes autonomously. The display never goes blank because host software stopped.
* **The host owns the words.** It writes ASCII through `CURSOR`/`CHAR` (four packed characters per
  bus write) and formats live ADC and DAC values itself.

`GEOMETRY` reports the character grid implied by the selected panel and font, so the host does not
hard-code 21×4 or 16×8 anywhere. One engine drives SSD1306 over SPI, SSD1331 over SPI and SSD1306
over I2C, selected by `CFG.PANEL`.

## Verification

Testbenches are cocotb (Python) on GHDL: free, headless, and runnable on every push in CI. The
argument for Python testbenches here is specific rather than fashionable — the interesting
properties of these blocks are *data* properties. A golden model of an AD7476A conversion, an
expected SSD1306 command sequence, or an expected framebuffer are all far easier to express in
Python than in VHDL, and the same field pack/unpack code the host driver uses can drive the
testbench, which means the register map is exercised the same way from both sides.

Conventions:

* One testbench directory per IP, with a thin VHDL wrapper that pins generics and flattens array
  ports so cocotb can reach them through VPI.
* A passing run leaves a `SUCCESS` marker, so an outer `make test` can distinguish "passed" from
  "never ran".
* Device models (AD7476A, DAC121S101, AD5541A, SSD1306) live in `sim/zmixsim/` as reusable BFMs
  written from the datasheet timing, not from the RTL — a model derived from the design under test
  proves nothing.

## Host stack

```
  user script / notebook
        │
  zmix.api          verbs:  adc.read_samples(n)   dac.set_volts(1.25)   oled.text(0, "hello")
        │
  zmix.drivers      per-IP driver classes, field-aware
        │
  zmix.regs         generated register definitions (pack/unpack)
        │
  zmix.transport    ── TCP/SCPI ──┐
                    ── HTTP/JSON ─┤   variant-specific
                    ── raw UDP ───┤
                    ── local mmap ┘   (on-board, no network)
```

The upper layers are identical across all four control-plane variants; only `zmix.transport`
changes. A script written against variant A runs unchanged against variant C.

## Build

Vivado is driven in non-project mode from `scripts/build.tcl`: `read_vhdl` → `synth_design` →
`opt/place/route` → `write_bitstream`, with the PS7 block design exported as Tcl. Everything is
text, everything diffs, and nothing depends on GUI state.

Two guardrails borrowed from PulsePins:

* the build fails if worst negative slack is negative or any path is unconstrained, rather than
  producing a bitstream that works until it does not;
* the git SHA and build timestamp are baked into `sysid`, so a board can always say exactly what it
  is running.
