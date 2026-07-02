**English** | [简体中文](README.zh_CN.md)

# Generic HD Audio Codec — Synthesizable SystemVerilog Model

A parameterized, **synthesizable** functional model of the Realtek
**ALC269 / ALC662 / ALC892 / ALC256** High Definition Audio codecs, implemented
from the public *Intel High Definition Audio Specification, Rev. 1.0a*. A single
`CHIP_ID` elaboration parameter selects the target device.

The model is verified against a spec-accurate HDA controller bus-functional
model (BFM) and synthesizes cleanly on AMD/Xilinx Vivado.

## Features

| Block | Description |
|-------|-------------|
| HDA link | 40-bit Command / 36-bit Response serial link (`hda_link`); double-pumped **DDR** SDO capture + single-pumped **SDR** SDI; DDR Frame-Sync detection immune to in-frame stream tags; zero-latency SDI Response (drives bit 499 at Start-of-Frame); 3-frame init sequence (Connect / Turnaround / Address) |
| Verb engine | Get/Set verbs: parameters (F00), connection select, amplifier gain/mute, converter format/stream, power state, pin control, GPIO, unsolicited response, etc. |
| Widget registers | Per-chip Capability ROM + writable widget state |
| Data path | DAC/ADC digital sample path, volume attenuation, mixer/mux routing |
| **High sample rate** | 48 kHz = 1, 96 kHz = 2, 192 kHz = 4 sample blocks per frame (per §3.3.34 Block Multiple) — the data path really moves multiple samples/frame |
| **Stream format** | `conv_format` is effective: bit depth (16/20/24-bit) and channel count (mono/stereo) alter the sample data |
| Stream tags | Outbound stream-tag filtering per DAC slot + inbound stream tags on SDI |
| S/PDIF | 1–2 independent S/PDIF serial output stubs |
| GPIO | 2–4 GPIOs with data/direction/wake/unsolicited control (ALC256 GPIO0 can mux as DMIC clock) |
| Beep generator | Programmable-frequency square-wave output |
| Power management | D0/D1/D2/D3 aggregation with per-block power-ready status |

## Supported chips

| `CHIP_ID` | Model | DAC | ADC | S/PDIF | GPIO | Target |
|-----------|-------|-----|-----|--------|------|--------|
| 0 | ALC269 | 2 | 2 | 2 | 2 | Laptop / mobile |
| 1 | ALC662 | 3 | 2 | 1 | 2 | Desktop 5.1 |
| 2 | ALC892 | 4 | 3 | 1 | 4 | Desktop 7.1 |
| 3 | ALC256 | 2 | 2 | 1 | 3 | Ultrabook / tablet |

PCM capabilities (all chips): 16 / 20 / 24-bit at 44.1 / 48 / 96 / 192 kHz.

## Repository layout

```
rtl/generic/   Parameterized synthesizable RTL (10 modules)
tb/            Testbenches + HDA controller BFM (codec + address protocol)
sim/           Vivado batch scripts, Icarus Verilog Makefile, timing XDC
USAGE.md       Integration / usage guide
```

## Quick start

### Vivado simulation

```powershell
cd sim
vivado -mode batch -source sim_hda_codec.tcl -tclargs all   # all four chips
vivado -mode batch -source sim_hda_codec.tcl -tclargs 3     # ALC256 only
vivado -mode batch -source sim_hda_addr.tcl  -tclargs all   # address-config tests
```

### Vivado synthesis

```powershell
cd sim
vivado -mode batch -source synth_hda_codec.tcl -tclargs 0   # ALC269
```

### Icarus Verilog

```bash
cd sim
make                 # ALC269 (default)
make CHIP=ALC892     # any chip
make all             # all four chips
```

> Note: `hda_link` uses SystemVerilog DDR (both clock edges). Vivado xsim is
> the reference flow; Icarus Verilog support depends on your iverilog version.

## Verification

The self-checking testbench (`tb/hda_codec_tb.sv`) runs 16 groups **G0–G15**:
identification & capability ROM, converter control, output/input path, GPIO,
beep, S/PDIF, power management, unsolicited responses, response framing, stream
tags, and **G15 high-sample-rate / stream-format** (verifies 1/2/4 sample blocks
per frame at 48/96/192 kHz, bit-depth masking, and mono duplication).

All four chips report `ALL TESTS PASSED` (0 errors), and all four synthesize
with **0 errors / 0 critical warnings**.

## Architecture highlights

- **Runtime-variable, backward-compatible frame geometry**: each DAC converter's
  slot span is computed at runtime from its sample-rate multiple; at 48 kHz the
  geometry is identical to the fixed single-block layout.
- **Clean-room, layered, synthesizable** design — 10 modules under a
  parameterized top, not a flat simulation class.

## Limitations & not implemented

This is a **functional / protocol-behavior model**, not a gate-accurate or
analog-accurate replica of real silicon. Known limitations:

- **Audio I/O are digital stubs.** `hp_out_*`, `front_out_*`, `mic*`, `line*`,
  etc. are digital sample buses — there is no real DAC/ADC, analog front-end,
  mixer arithmetic, or sample-rate converter. Downstream sinks only see the most
  recent sample.
- **Volume is a shift approximation.** Amplifier gain uses power-of-two shifts
  (~6 dB/step), not the HDA 0.25 dB-scale amplifier tables.
- **High sample rate is DAC-playback only.** 96/192 kHz deliver 2/4 sample
  blocks per frame on the DAC path; the ADC-capture path still emits one block
  per frame (its data source is a static stub, so multi-block capture is moot).
- **44.1 kHz-base rates are integer-approximated.** 44.1 / 88.2 / 176.4 kHz reuse
  the same integer block-multiple as the 48 kHz base; the true fractional-rate
  sample distribution (~0.919 sample/frame) is not modeled.
- **Channels > 2 use multiple converters.** Each converter's sample block is a
  fixed 2-channel container; surround relies on several stereo converters
  (standard HDA routing) rather than one wide converter.
- **Verb coverage is functional, not exhaustive.** Common Get/Set verbs work;
  some rarely-used verbs, processing coefficients, and optional widget behaviors
  are simplified or stubbed. Only the Audio Function Group is modeled (no Modem).
- **Stream routing is slot-fixed + tag-gated**, not fully dynamic
  converter-to-any-packet matching.
- **Power management is state aggregation only** (D0–D3 status), with no real
  power/clock-gating behavior or timing.
- **Icarus Verilog is best-effort.** The reference flow is Vivado xsim; the DDR /
  SystemVerilog constructs may not build on every iverilog version.

PRs to lift any of these are welcome — code comments cite the HDA spec section
for each block.

## About

Generated with the assistance of **Claude Opus 4.8** (Anthropic) and open-sourced
to save others some tokens — if you need an HD Audio codec model to build on or
learn from, help yourself.

It's an independent, clean-room implementation of the **public** Intel HD Audio
Specification (Rev. 1.0a); no proprietary datasheets or third-party code are
included.

## License

MIT © 2026 delsz4c — see [LICENSE](LICENSE).

## Disclaimer

Not affiliated with or endorsed by Intel or Realtek. Product names (Intel,
Realtek, "High Definition Audio", ALC*) are trademarks of their respective
owners, used only to describe interface compatibility.
