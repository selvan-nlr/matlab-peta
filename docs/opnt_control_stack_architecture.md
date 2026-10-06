# OPNT experiment control stack: lessons from QubitControlStack, applied to RFSoC

Status: **draft for discussion**. No code. This document:

1. Explains how [`gwrxuk/QubitControlStack`](https://github.com/gwrxuk/QubitControlStack) is built, based on its source (commit `1e13d13`, its only commit when this was written).
2. Answers three questions: how to rebuild that setup on an RFSoC, whether PYNQ can carry timestamp and two-way time transfer (TWTT) data to the host, and whether the quantum library can be renamed and reused.
3. Proposes a layered architecture for an optical PNT (OPNT) / laser-satcom experiment built on GTH/GTY transceivers and RF-ADC/RF-DAC tiles. It reuses the conventions this repository already has (the `regmap/*.yaml` single source of truth, a single AXI4-Lite slave, cocotb testbenches and swappable transports).

> **About accuracy.** Statements about QubitControlStack come from reading its code; file and line references are given. Statements about AMD/Xilinx, PYNQ and MATLAB products come from my general knowledge, not from this repo. They are marked **[verify]** wherever a version, a throughput figure or an API name could be wrong or out of date. Check those against the current vendor documentation before you base a design decision on them. Numbers marked "≈" are order-of-magnitude estimates, not measurements.

---

## 1. What QubitControlStack actually is

### 1.1 Shape of the code

About 8.8 k lines in total, all Python. There is **no FPGA, firmware, driver or embedded code** in the repo. It is a host-PC library that would drive bench instruments (AWG, signal generator, digitizer) over VISA/SCPI. Today it runs only in simulation.

```
                      ┌──────────────────────────────────────────────┐
  User                │  qcs CLI (click + rich)        cli.py        │
  interfaces          │  Jupyter (Dockerfile.jupyter)                │
                      │  scripts/run_analysis.py, examples/          │
                      └───────────────┬──────────────────────────────┘
                                      │ Python calls
                      ┌───────────────▼──────────────────────────────┐
  Experiment layer    │  core/experiment.py  Experiment, Sweep,      │
                      │     Rabi / T1 / Ramsey subclasses            │
                      │  core/calibration.py CalibrationManager(JSON)│
                      └───────┬─────────────────────────┬────────────┘
                              │                         │
                      ┌───────▼───────────┐   ┌─────────▼──────────────┐
  Domain / DSP        │ core/sequence.py  │   │ rf/pulse_generator.py  │
  (numpy, host-side)  │ gate → pulse      │   │ rf/iq_modulator.py NCO │
                      │ compiler          │   │ rf/mixer_calibration.py│
                      └───────┬───────────┘   └────────────────────────┘
                              │ numpy waveforms
                      ┌───────▼──────────────────────────────────────┐
  Hardware            │ hardware/instrument_manager.py  registry,    │
  abstraction         │   connect/arm/run/stop ordering, JSON config │
                      │ hardware/base.py  Instrument[ConfigT] (ABC)  │
                      │ hardware/awg.py, digitizer.py,               │
                      │   signal_generator.py (SCPI strings)         │
                      └───────┬──────────────────────────────────────┘
                              │ pyvisa  (or "simulate=True" short-circuit)
                      ┌───────▼──────────────────────────────────────┐
  Transport           │ VISA TCPIP / USB / GPIB, serial (enum only)  │
                      └──────────────────────────────────────────────┘
```

### 1.2 Patterns worth copying

| Pattern | Where | Why it carries over to OPNT |
|---|---|---|
| **Generic instrument base class** `Instrument(ABC, Generic[ConfigT])` with a typed `*Config` dataclass per instrument | `hardware/base.py:38-252` | A common lifecycle (`connect / configure / reset / check_errors`, context manager) for the RFSoC board, time-interval counters, laser drivers, power meters and a GNSS/WR reference |
| **Explicit state enum** `DISCONNECTED → CONNECTED → CONFIGURED → ARMED → RUNNING / ERROR` | `hardware/base.py:28-35` | Maps directly onto the gateware's `IDLE / ARMED / CAPTURING / FAULT` status register |
| **Simulation built into the base class** (`simulate=True` short-circuits `write`/`query`) | `hardware/base.py:101-212` | Lets the whole experiment pipeline run in CI without the board. You already do this for gateware with cocotb |
| **InstrumentManager** with ordered bring-up (sources → generators → acquisition) and `arm_all → run_all` | `hardware/instrument_manager.py:405-502` | Ordered bring-up matters even more for RFSoC: reference clock → LMK/LMX → RF tiles → MTS → GT links → timing core → DMA |
| **Experiment template method**: `setup → build_sequence(sweep point) → execute → process_result`, plus an N-D sweep from `np.unravel_index` and a progress callback | `core/experiment.py:195-420` | The same skeleton fits "sweep link delay / laser power / code phase, then measure the TWTT offset" |
| **Strong unit types** (`Frequency`, `Duration` as frozen dataclasses) | `core/types.py:44-101` | Timing work needs unambiguous units. Extend this with fixed-point picosecond time types (see §5.4) |
| **Packaging**: `pyproject.toml` with a `qcs` console script, `[dev]` extras, ruff, mypy-strict, pytest | `pyproject.toml` | Copy as is |
| **Docker**: multi-stage slim image, non-root user, `/data` and `/config` volumes, compose profiles (`dev`, `test`, `jupyter`) | `Dockerfile`, `docker-compose.yml` | Copy for the **host PC** side. It does not belong on the target (§2.4) |

### 1.3 Gaps and defects found while reading (read these before reusing anything)

The README presents the repo as hardware-ready. The code shows that the hardware path is incomplete:

| # | Finding | Evidence |
|---|---|---|
| 1 | Experiments never upload waveforms on real hardware: the per-channel upload loop body is `pass` | `core/experiment.py:362-366` |
| 2 | Digitizer readback returns zeros: `_read_channel_data` ends in `return np.zeros(...)  # Placeholder` | `hardware/digitizer.py:283-288` |
| 3 | `qcs init --simulate` is `is_flag=True, default=True`, so you cannot turn simulation off from the CLI. The CLI experiment commands never call `set_hardware()`, so they always take the simulated path | `cli.py:41`, `core/experiment.py:354-356` |
| 4 | `--config` is parsed and stored but never used | `cli.py:23,37` |
| 5 | `AWG.arm()` sends `*OPC?` with `write()` rather than `query()`, which leaves an unread response in the instrument's output buffer | `hardware/awg.py:254` |
| 6 | The README says "JSON/HDF5" and `h5py` is a dependency, but results are only ever written as JSON. No `h5py` import exists | `core/experiment.py:134-164` |
| 7 | `requirements.txt` pulls in `aiohttp`, `websockets`, `asyncio-mqtt`, `pandas`, `plotly`, `pyserial`, none of which are imported. There is **no network API or server**. The "async operations" in the `base.py` docstring are not implemented | `requirements.txt`, `hardware/base.py:7` |
| 8 | Docker sets `QCS_DATA_DIR=/data`, but nothing reads it. Data goes to `./data` relative to the working directory (`/app/data`), **not** to the mounted `/data` volume | `Dockerfile`, `core/experiment.py:96` |
| 9 | The SCPI dialect is a single generic one. `WLIST:WAV:NEW` looks like Tektronix syntax, yet the README lists Keysight/ZI/Tabor as supported. A computed binary-block `header` is never used **[verify the exact vendor syntax if you care]** | `hardware/awg.py:155-167` |
| 10 | The README says "MIT License - see LICENSE file", but **there is no LICENSE file** in the repo; only `pyproject.toml` declares MIT. Reuse is legally ambiguous until the author adds one. Ask them, or reuse ideas only, as this repo already does with PulsePins | repo root |
| 11 | Timing model: every sweep point runs a Python loop (build → compile → upload → arm → acquire), and there is no hardware sequencer or streaming. That is fine for slow qubit calibration scans. It is **fundamentally unsuitable** for continuous time-tag streams | `core/experiment.py:322-343` |
| 12 | The Jupyter compose service disables the token and password and runs `--allow-root`. That is fine on an isolated lab PC and unsafe on any shared network | `docker-compose.yml` |

**Bottom line:** QubitControlStack is a good *template for host-side software structure*. It gives you **no** model for target-side real-time behaviour, DMA, deterministic timing, or a control API that MATLAB could call. Those are the parts OPNT needs most.

### 1.4 Is there an API callable from MATLAB?

No. There is no server, socket protocol or C ABI. Your options, all external to the repo:

- **MATLAB → Python in-process.** MATLAB can call Python modules directly (`pyenv`, then `py.<module>.<function>(...)`). It works for a library like this, but numpy ↔ MATLAB array conversion and the supported Python versions depend on your MATLAB release **[verify the compatibility table for your MATLAB release]**. It also couples MATLAB's process to the Python environment, so I do not recommend it for the lab control path.
- **MATLAB → network API (recommended).** Give the target a language-neutral control interface (SCPI over TCP, or gRPC/ZeroMQ/HTTP-JSON). MATLAB then talks to it with `tcpclient`/`visadev` or HTTP calls **[verify which toolbox these need in your release]**. This is the same idea as variants A and D in this repo's README.
- **Model-Based Design.** For the gateware itself, MathWorks offers HDL Coder / SoC Blockset flows with RFSoC support **[verify the current support package name and the supported boards]**. Treat those models as a *source of IP cores* that plug into the register-map contract below. They do not replace the control stack.

---

## 2. Q1: Best way to reproduce this setup on an RFSoC (embedded Linux vs PYNQ)

### 2.1 Recommendation

Use **one gateware design and one register map with two software personalities**:

| Phase | Target OS | Why |
|---|---|---|
| Bring-up and exploration | **PYNQ** image for the board (for example RFSoC 4x2, ZCU111, ZCU208/216, if a PYNQ image exists for your board and release **[verify]**) | Fastest path to "see an RF-ADC spectrum in a notebook". It provides `Overlay`, `MMIO`, `allocate` (contiguous DMA buffers) and AXI DMA drivers, and RFSoC boards have Python packages for the RF data converter and clocking (`xrfdc`, `xrfclk`) **[verify package names and board support for your PYNQ version]** |
| Campaign / flight-representative | **Custom Yocto/PetaLinux image** (or AMD's successor flow **[verify: AMD has been transitioning tooling; check the current recommended embedded Linux flow]**), with a C/C++ daemon, UIO/DMA-engine drivers and a small Python client | Reproducible, version-locked rootfs. No Jupyter on the target. Deterministic service start-up. Closer to what an avionics or ESA review would accept |

Both run the **same bitstream, the same device tree fragments and the same `regmap/*.yaml`**, so moving from phase 1 to phase 2 swaps only the transport layer. That is the "four control planes, one design" idea already in `README.md`.

A strong external reference for this exact problem shape (RFSoC + PYNQ for physics experiment control) is Fermilab's **QICK** (Quantum Instrumentation Control Kit), an open-source project. From memory, it pairs a PYNQ host with an RFSoC tProcessor and timed signal generators/readouts **[verify its current architecture and licence on its repository before relying on this description]**. It is a better RFSoC model than QubitControlStack, which has no target side.

### 2.2 Why not PYNQ alone

- PYNQ is a Python-on-target environment. Jupyter, Python GC pauses and a general-purpose rootfs on the target make results harder to reproduce and harder to certify.
- The PYNQ release cadence and board support lag behind Vivado releases **[verify the current PYNQ version vs your Vivado version]**. Locking your gateware to a PYNQ-supported Vivado version can be a real constraint for GTY/RFSoC Gen3 features.
- Real-time work (TWTT servo, tag ingest) should never depend on Python on the target. In PYNQ it would.

### 2.3 Why not bare-metal

You already know Zynq US+ bare-metal. Keep bare-metal or FreeRTOS **on the RPU (Cortex-R5)** for tight loops such as a TWTT servo or a laser pointing loop, and run Linux on the APU for networking and data. OpenAMP/libmetal are the usual glue between the two **[verify the current recommended inter-processor communication (IPC) approach in your toolchain version]**. That is also a natural place to grow your RTOS skills.

### 2.4 Where Docker belongs

| Location | Docker? |
|---|---|
| **Host PC / lab server** | **Yes.** Copy QubitControlStack's pattern: an `opnt-host` image with CLI + analysis + Jupyter profile, `/data` and `/config` volumes (and actually read `OPNT_DATA_DIR`, unlike finding #8) |
| **CI** | **Yes.** One image with GHDL + cocotb + Python for the host-only lane (this repo's `make check`), optionally a second image with Vivado for builds on a licensed runner |
| **RFSoC target** | **No by default.** Use a Yocto-built rootfs with systemd services. Containers on the target add complexity (device nodes, UIO, CMA/DMA buffers, real-time scheduling) for little gain |

---

## 3. Q2: Can PYNQ offload time tags and TWTT data to the host over PS-PL AXI + DMA?

**Short answer: yes for moving the data. Do not let Python sit in the timing path.** The timestamps must be **generated and latched in the PL**. The PS, whether running PYNQ or a C daemon, only moves already-timestamped records.

### 3.1 Data path

```
   PL (fabric)                                     PS (APU, Linux)              Host PC
 ┌───────────────────────────────────────────┐   ┌─────────────────────┐   ┌──────────────┐
 │ events: GT RX comma/frame, RF-ADC         │   │                     │   │              │
 │ threshold, PPS, laser pulse detect        │   │  DMA ring buffer    │   │  opnt client │
 │         │                                 │   │  (CMA / allocate()) │   │  HDF5 writer │
 │         ▼                                 │   │        │            │   │  MATLAB      │
 │ ┌──────────────┐   ┌──────────────────┐   │   │        ▼            │   │  analysis    │
 │ │ time-tag     │──►│ record packer    │───┼AXIS► AXI DMA (S2MM) ───┼──►│              │
 │ │ unit (TDC +  │   │ {ts, ch, flags,  │   │ HP │  daemon / PYNQ    │TCP/UDP          │
 │ │ coarse ctr)  │   │  seq#, crc}      │   │port│  batches records   │10GbE│           │
 │ └──────▲───────┘   └──────────────────┘   │   │                     │   │              │
 │        │ common timebase (local TAI ctr)  │   └─────────────────────┘   └──────────────┘
 │ ┌──────┴───────┐                          │
 │ │ timing core  │◄── 10 MHz / PPS / WR     │
 │ └──────────────┘                          │
 └───────────────────────────────────────────┘
```

### 3.2 Design rules

1. **Tag in hardware, against one timebase.** Coarse counter on a GT-derived or reference-derived clock + fine interpolation (carry-chain TDC or a DDMTD-style phase measurement, the technique White Rabbit uses **[verify details in the WR literature]**). The record carries the full timestamp; the PS never "adds" time.
2. **Records, not raw samples.** A fixed-width record (for example 128 bits: 64-bit timestamp in ps or sub-ps units, channel, flags, sequence number, CRC/parity) keeps the DMA stream small and self-describing. Put the layout in the regmap YAML so the generator emits the VHDL packer, the C struct and the numpy dtype from one description. That extends this repo's "nothing describes a register twice" rule to stream formats.
3. **Sequence numbers + overflow flags in every record.** Then the host can *prove* that nothing was dropped. The DMA path is lossless only if the PS keeps up.
4. **Size the link before choosing the transport.** Rough arithmetic: 16-byte records at 1 M events/s = 16 MB/s, comfortable on 1 GbE (practical ≈ 100 MB/s). At 10 M events/s = 160 MB/s you need 10 GbE (the PS GEM or PL MAC) or on-target reduction **[verify achievable sustained rates on your board; these are estimates]**.
5. **The AXI HP port is not the bottleneck.** An HP port at 128 bits × a few hundred MHz has a theoretical capacity of several GB/s **[verify for your clocking]**. In practice the limits are DMA descriptor handling, Python per-call overhead (PYNQ `transfer()`/`wait()` costs roughly tens to hundreds of µs per call **[verify by measurement]**) and the network. Use large buffers (≥ 1 MB) and a ring of buffers, not one DMA call per event.
6. **TWTT computation.** For a symmetric path, with t1/t4 the local transmit/receive tags and t2/t3 the remote ones:
   `offset = ((t2 − t1) − (t4 − t3)) / 2`, `delay = ((t2 − t1) + (t4 − t3)) / 2`.
   Any asymmetry (fibre/free-space, GT TX/RX latency, Sagnac for space links) shows up directly as offset error. **GT latency must be deterministic** (buffer bypass / fixed-latency configuration) and calibrated. That is a gateware decision, not a software one.
7. **Where each piece runs.**
   - PL: tagging, packing, optionally the per-exchange offset/delay arithmetic.
   - RPU (FreeRTOS/bare-metal): the closed-loop servo (DAC/NCO steering of the local oscillator) when the loop bandwidth needs bounded latency.
   - APU: the record stream to the host, configuration, logging.
   - Host: long-term analysis (Allan/TDEV, residuals, link budgets), using MATLAB or Python.

### 3.3 Is PYNQ good enough?

| Use | PYNQ OK? |
|---|---|
| Bring-up: read RF-ADC samples, check GT link status, look at a few thousand tags in a notebook | Yes |
| Streaming tags continuously to a host at ≥ MB/s for hours | Workable with a buffer ring and a background thread, but a C daemon is more robust **[verify sustained throughput on your setup]** |
| Closed-loop timing servo | No. Use PL or RPU |

---

## 4. Q3: Can we rename the quantum library and evolve it for OPNT?

**Recommendation: no, do not rename and fork it. Re-implement the patterns in a new package** (for example `opnt`), for these reasons:

1. **Licensing** (finding #10). There is no LICENSE file. Until there is one, copying code is legally ambiguous. Reusing *ideas*, as this repo already does with PulsePins, is fine.
2. **Little of the domain code transfers.**

| QubitControlStack module | Keep idea? | OPNT counterpart |
|---|---|---|
| `hardware/base.py` (Instrument ABC, state, simulation) | **Yes** | `opnt.hal.Instrument` with transports from this repo's `zmix.transport` design (SCPI-TCP, local mmap/UIO, DMA stream) |
| `hardware/instrument_manager.py` | **Yes, extended** | `opnt.system.Testbed`: ordered bring-up incl. clocks, RF tiles, MTS, GT links, timing lock |
| `hardware/awg.py`, `digitizer.py` (SCPI) | Pattern only | `RfDac`, `RfAdc`, `GtLink`, `TimeTagger` drivers over the generated register map, plus a `ScpiInstrument` for bench gear (TIC/counter, power meter, oscilloscope) |
| `hardware/signal_generator.py` | Yes, as bench gear | Reference synthesisers / laser driver current sources |
| `rf/iq_modulator.py`, `NCO`, `mixer_calibration.py` | **Partially** | Useful as *host-side reference models* for the RF-DAC/ADC IQ paths and as test oracles for cocotb. The RFSoC data converter has its own on-chip correction blocks **[verify which (QMC, coarse delay, etc.) in your device generation]** |
| `rf/pulse_generator.py` (Gaussian/DRAG/etc.) | **No** | Replace with ranging codes / PRN generation, pulse-position modulation, and optical modulation formats |
| `core/sequence.py` (quantum gates) | **No** | Replace with an "observation schedule": time-scheduled transmit/measure windows on a hardware sequencer |
| `core/experiment.py` (sweep template) | **Yes** | `opnt.experiment.Experiment` with streaming acquisition rather than per-point loops (finding #11) |
| `core/calibration.py` (JSON, expiry) | **Yes** | Delay calibration tables per link/GT/cable, with validity periods and temperature tags |
| `visualization/*` (Rabi/T1 fits) | **No** | Time-offset residuals, Allan/TDEV, link-delay vs time, eye/constellation |
| `cli.py`, Docker, pyproject | **Yes** | `opnt` CLI with commands such as `status`, `arm`, `twtt run`, `stream record`, `calibrate gt-delay` |

3. **The hard part is missing.** The value in an OPNT stack lies in the gateware, the timing chain and the streaming. QubitControlStack has none of them.

---

## 5. Proposed OPNT architecture

### 5.1 Layered view

```
┌───────────────────────────────────────────────────────────────────────────────────┐
│ APPLICATION LEVEL (host PC, Docker)                                               │
│  • opnt CLI (click)       • Jupyter notebooks     • MATLAB scripts / Simulink     │
│  • Experiments: TWTT session, ranging sweep, link-budget scan, GT delay cal       │
│  • Analysis: Allan/TDEV, residuals, HDF5 archive with run metadata                │
└──────────────▲─────────────────────────────────────▲──────────────────────────────┘
               │ Python API                          │ SCPI/TCP or gRPC (language-neutral)
┌──────────────┴─────────────────────────────────────┴──────────────────────────────┐
│ LIBRARY / DRIVER LEVEL (host, same package also importable on target)             │
│  opnt.api        verbs: link.lock(), tagger.stream(), twtt.measure(n)             │
│  opnt.drivers    RfAdc, RfDac, GtLink, TimeTagger, TimingCore, Sysid              │
│  opnt.regs       GENERATED from regmap/*.yaml (+ stream record dtypes)            │
│  opnt.transport  scpi_tcp | grpc | local_uio | dma_stream | simulated             │
└──────────────▲────────────────────────────────────────────────────────────────────┘
               │ Ethernet (1/10 GbE)
┌──────────────┴────────────────────────────────────────────────────────────────────┐
│ TARGET: RFSoC PS                                                                  │
│  APU / Linux (Yocto, or PYNQ in bring-up)                                         │
│   • opntd daemon (C/C++): SCPI/gRPC server, register access via UIO,              │
│     DMA ring readers, record forwarding, health/telemetry                         │
│   • kernel: UIO, dmaengine (AXI DMA), CMA, RFdc + clock chip drivers [verify]     │
│  RPU / FreeRTOS or bare-metal                                                     │
│   • TWTT / clock-steering servo, watchdog, safe-state on fault                    │
│  Shared: OCM/DDR mailbox via OpenAMP / libmetal [verify]                          │
└──────────────▲───────────────────────▲────────────────────────────────────────────┘
               │ AXI4-Lite (control)   │ AXI4 HP / HPC (DMA streams)
┌──────────────┴───────────────────────┴────────────────────────────────────────────┐
│ TARGET: RFSoC PL (gateware)                                                       │
│  ip/common   axi4lite_regfile (the ONLY AXI-Lite slave, already in this repo)     │
│  ip/sysid    bitstream identity, ABI version, capabilities                        │
│  ip/timing   local timebase (TAI counter), PPS in/out, 10 MHz discipline,         │
│              DDMTD / phase detector, optional White Rabbit core [verify licence]  │
│  ip/tagger   multi-channel time-tag unit (coarse + fine), record packer → AXIS    │
│  ip/gt_link  GTH/GTY framing, deterministic-latency config, comma alignment,      │
│              TX/RX timestamp taps, PRBS/BER counters                              │
│  ip/rf_tx    RF-DAC path: PRN/ranging code gen, NCO, modulator, sequencer         │
│  ip/rf_rx    RF-ADC path: DDC, correlator / matched filter, threshold → event     │
│  ip/seq      hardware sequencer: time-scheduled TX/RX windows (replaces           │
│              QubitControlStack's Python per-point loop)                           │
│  AXI DMA (S2MM for tags/samples, MM2S for waveform/code tables)                   │
└──────────────▲───────────────────────────────────────▲────────────────────────────┘
               │ GTH/GTY serial                        │ RF-ADC / RF-DAC tiles
┌──────────────┴───────────────────────────────────────┴────────────────────────────┐
│ PHYSICAL / INSTRUMENTS                                                            │
│  optical terminal (laser driver, modulator, photodiode/APD front-end, FSO path)   │
│  reference: GNSS-disciplined oscillator / maser / WR switch, PPS + 10 MHz         │
│  bench: time-interval counter, oscilloscope, optical power meter, attenuators     │
└───────────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 Block responsibilities

| Layer | Block | Owns | Does not own |
|---|---|---|---|
| PL | `timing` | The single local timebase every tag refers to | Any decision about steering (that is the servo's job) |
| PL | `tagger` | Hardware timestamps + record packing, overflow/drop counters | Network formatting |
| PL | `gt_link` | Deterministic-latency serial links, TX/RX time taps | Delay *calibration values* (stored host-side and loaded into registers) |
| PL | `rf_tx` / `rf_rx` | Code generation, DDC/correlation, event generation | Long integrations best done on host |
| PL | `seq` | Time-scheduled actions with cycle accuracy | Experiment logic (sweeps, retries) |
| RPU | servo | Bounded-latency control loops, safe state | Data logging |
| APU | `opntd` | Control API, DMA rings → network, telemetry, config load | Anything timing-critical |
| Host | `opnt` lib | Typed drivers generated from YAML, transports, simulation | Real-time behaviour |
| Host | apps | Experiments, analysis, archiving, MATLAB integration | Register-level details |

### 5.3 Control plane vs data plane

QubitControlStack mixes the two; every point is a query/response round trip. For OPNT, keep them separate:

- **Control plane:** low rate, request/response. Register reads and writes, arming, configuration. Use SCPI over TCP (bench-instrument compatible, works from MATLAB, PyVISA and plain sockets) or gRPC if you want typed schemas.
- **Data plane:** high rate, one-way stream of self-describing records with sequence numbers. Raw TCP/UDP from `opntd`, or a PL UDP engine (this repo's variant C) if the PS becomes the bottleneck.
- **Telemetry plane:** periodic health (temperatures, lock states, GT status, dropped records), pushed at around 1 Hz.

### 5.4 Conventions to carry over from this repository

1. **Extend `regmap/*.yaml`** to describe stream record layouts as well as registers. The generator emits a VHDL packer, a C struct and a numpy dtype from that one description.
2. **`sysid` first.** The host refuses to run on an ABI mismatch, which matters even more when PYNQ and Yocto images share one bitstream.
3. **cocotb testbenches with datasheet-derived models.** Examples: a GT link partner model with configurable latency, and a time-tag source with known ground truth. The host `simulated` transport can reuse the same models, so the CLI runs end-to-end in CI. That is QubitControlStack's simulation idea, but backed by the real register map.
4. **Units as types.** Use fixed-point or integer picosecond types for time on the host. Never float seconds for absolute timestamps: a float64 has ≈ 15–16 significant digits, so at TAI-epoch magnitudes (~10⁹ s) the resolution falls to around 100 ns **[verify the exact figure for your epoch choice]**.
5. **Timing-closure and SHA guards** stay in the build exactly as described in `docs/architecture.md`.

### 5.5 MATLAB integration (model-based design friendly)

```
MATLAB / Simulink
   │  (a) control:  tcpclient → SCPI on opntd          [verify toolbox requirements]
   │  (b) data:     read HDF5 written by opnt host app, or subscribe to the stream
   │  (c) design:   HDL Coder IP → packaged as ip/<block> with its own regmap YAML
   ▼
opnt stack (unchanged)
```

Rule (c) is what keeps MBD-generated IP inside the architecture: a generated core still sits behind the one `axi4lite_regfile`, or gets a YAML that describes its own AXI-Lite map, so drivers and documentation are still generated.

---

## 6. Suggested build-up order (milestones, not code)

1. **Host skeleton.** `opnt` package layout, CLI, Docker host image, simulated transport. No hardware needed.
2. **Bring-up on PYNQ.** sysid + RF-ADC capture + GT loopback with PRBS, all from notebooks.
3. **Timing core + tagger in cocotb, then on hardware.** Validate tag accuracy against a bench time-interval counter.
4. **DMA streaming.** Buffer ring and sequence-number loss check. Measure sustained throughput (replaces every **[verify]** throughput estimate above).
5. **TWTT over a GT link in loopback, then over fibre, then over the free-space optical path.** Calibrate asymmetries at each step.
6. **Move to the Yocto image + `opntd` daemon + RPU servo.** Keep PYNQ only for lab exploration.
7. **MATLAB integration** via the SCPI control plane + HDF5 data.

---

## 7. Open questions (please answer; these change the design)

1. **Which RFSoC device and board?** (Gen1/2/3/DFE, ZCU111/208/216, RFSoC 4x2, custom.) This decides PYNQ availability, GT types (GTY on RFSoC; GTH depends on the part **[verify for your device]**) and the RF tile count.
2. **Required timing performance:** target TWTT precision and accuracy (ps? tens of ps?), and expected event/tag rate. These size the TDC design and the data link.
3. **Reference:** GNSS-DO, White Rabbit, or a lab maser? Is White Rabbit compatibility a requirement or just an option?
4. **What does "GTH/GTY" carry?** An optical comms framing (for example a CCSDS optical protocol **[verify which standard applies]**), your own ranging frames, or both?
5. **Deployment target:** lab/OGS only, or must this trace toward a flight-representative design? That changes the Linux/RPU split and the role of PYNQ.
6. **MATLAB release and toolboxes available**, and whether MATLAB must *control* the experiment or only *analyse* it.
7. **Ownership of QubitControlStack code:** do you need anything beyond ideas? If so, ask the author to add a LICENSE file first.
