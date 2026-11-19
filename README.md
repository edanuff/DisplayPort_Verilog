# DisplayPort_Verilog

An open-source Verilog implementation of a DisplayPort source (transmitter)
for FPGAs, with **audio support**, released under the MIT License.

Originally written by Mike Field (hamster) for the Xilinx Artix-7 (Digilent
Nexys Video); since restructured into a self-contained, instantiable
`dp_transmitter` module with an ergonomic interface modelled on the
hdl-util HDMI core, targeting **Gowin GW5AT (Arora V)** parts with GTR12
transceivers as the primary platform, with the original Artix-7 support
retained under `examples/`. A third PHY backend drives DisplayPort out of
smaller **Gowin GW5A parts that have no transceivers** (GW5A-15/25) by using
the hardened **MIPI D-PHY** as a raw serializer — see
[`examples/tang_primer_25k/`](examples/tang_primer_25k/).

## The module

```systemverilog
dp_transmitter #(
    .LANE_COUNT      (2),        // 1, 2, or 4
    .LINK_RATE_MBPS  (2700),     // HBR (1620 = RBR also verified)
    // video timing: 1920x1080p60 (2200x1125, pixel clock 148.5 MHz
    //   = 135 MHz link word clock x 11/10); default params are 720p60
    .AUDIO_RATE      (48000),    // 44100 | 48000
    .AUDIO_BIT_WIDTH (16)
) dp (
    .clk100 (clk100),            // AUX/management clock
    .refclk0(serdes_refclk),     // SERDES reference
    .reset  (reset),
    // pull-style video: the module outputs coordinates and its own
    // pixel clock (DP synchronous clocking); you supply the pixel
    .clk_pixel(clk_pixel), .cx(cx), .cy(cy), .rgb(rgb),
    // HDMI-style audio: one-clk_pixel-wide strobe at the sample rate
    .clk_audio(strobe), .audio_sample_word('{left, right}),
    // DP main link + AUX/HPD (analog buffers live in the board top)
    .dp_tx_lane_p(...), .dp_tx_lane_n(...),
    .hpd(hpd), .auxch_in(...), .auxch_out(...), .auxch_tri(...),
    .link_established(...), .video_live(...)
);
```

Everything is inside: video timing generation, pixel CDC, transfer-unit
packing, MSA, audio secondary data packets (Audio_TimeStamp with measured
Maud, Audio_Stream with IEC 60958 subframes, Audio InfoFrame) with the
RS(15,13)/GF(16) ECC and nibble interleaving per DP 1.1a, VB-ID audio
mute handling, scrambling, link training patterns, AUX-channel link
policy, and fabric 8b/10b for raw-mode transceivers.

## Status

**Hardware-proven and in production use.** This core is the DisplayPort
output of the [a2fpga project](https://github.com/a2fpga/a2fpga_core)'s
a2mega board (an Apple II FPGA coprocessor), driving USB-C DP Alt Mode
through the transceiver quads of **two different Gowin Arora-V dies** —
GW5AT-60 and GW5AST-138 (Tang Mega 60K/138K SOMs) — at 2-lane HBR,
1080p60 with 48 kHz audio, into USB-C hubs, DP→HDMI converters, and
DP monitors. Measured on hardware, not assumed:

- multi-hour streaming soaks with the sink's DPCD symbol-error counters
  (0x210-0x213, read continuously by the core's own instrumentation)
  holding **zero errors** — bounding the symbol error rate below ~1e-12,
  orders of magnitude inside the DP 1e-9 BER compliance target
- zero unintended link teardowns across overnight runs; training,
  recovery, and IRQ servicing exercised against real hubs, including
  deliberately hostile conditions (deferred EDID, garbled/lost AUX
  replies, HPD flap storms)
- the closed-loop AUX policy (polite attach pacing, ESI sink-IRQ
  servicing, training-read recovery) was built from and validated
  against wire captures of a conformant source (an Apple Silicon Mac)
  driving the same sinks

The same core also drives **4-lane RBR 1080p60 with 48 kHz audio over the
GW5A-25's hardened MIPI D-PHY** used as a raw serializer (no transceivers on
that die), through an SN75DP130 redriver into USB-C DP Alt Mode, on the
a2fpga a2p25 board — see [`examples/tang_primer_25k/`](examples/tang_primer_25k/)
and its [DESIGN.md](examples/tang_primer_25k/DESIGN.md). The 10->16 gearbox
and the D-PHY PHY bank are gated by their own testbenches
(`test_benches/test_dp_dphy_tx.sv`, `test_benches/test_transceiver_bank_dphy.sv`).

Every layer is also gated by Icarus Verilog testbenches with
*independent* C-model checkers (`misc/`):

- video: pixel-exact frame reconstruction in three modes - **1080p60 @
  HBR x2 (the production target)**, 720p60 @ RBR x2, and 800x600 @
  RBR x1 (fractional transfer-unit packing)
- audio: SDP extraction with independently-computed ECC, subframe field
  checks, and PCM sample-continuity across packets; Maud measurement
  converges under a +200 ppm strobe
- SDP wire format: byte-for-byte against `misc/dp_sdp_golden.py`, which
  reproduces the DP 1.1a spec test vectors
- 8b/10b: exhaustive round-trip incl. TPS2 forced-disparity handling
- link training: full AUX exchange to link-established against a
  scripted sink model; DPCD link-rate byte checked for both RBR (0x06)
  and HBR (0x0A)
- place & route (Gowin EDA, GW5AT-60 with the generated GTR12 SERDES IP
  and PLLA clocks): timing closed at the 1080p60/HBR rates - 135 MHz
  link domain, 148.5 MHz pixel domain - with zero violations and a
  generated bitstream; 5% LUT, 12% BSRAM (see examples/tang_mega/)

Authoritative resource usage comes from the Gowin place & route of the
full design (examples/tang_mega/, GW5AT-60): **2881 LUT (5%), 2343
registers (4%), 13 BSRAM (12%)** - leaving ~95% of the device for the
system the transmitter is embedded in. For quick development-loop
checks without the Gowin tools, Yosys (`synth -lut 4` / `synth_gowin`)
gives per-module estimates: roughly 800 LUTs for the TU packer, 800 for
the SDP engine, 80 per lane for 8b/10b, and 6 BSRAMs for the pixel
FIFO.

## Layout

```
src/dp_transmitter.sv   the top-level module
src/core/               main-link datapath (idle/scrambler/training/skew)
src/video/              timing generator, CDC FIFO, TU packer, MSA
src/audio/              sample buffer, Maud measurement, SDP engine
src/auxch/              AUX channel, EDID/DPCD, link training policy
src/gowin/              GW5A platform: fabric 8b/10b, SERDES bank
                        (transceiver_bank_gowin) and the MIPI D-PHY bank
                        (transceiver_bank_dphy + dp_dphy_tx gearbox)
src/artix7/             original GTP transceiver bank (legacy)
src/test_streams/       hamster's hand-coded test sources (regression)
examples/tang_mega/     GW5AT board top + SERDES IP generation notes
examples/tang_primer_25k/ GW5A-25 board top: DP over the MIPI D-PHY (no
                        transceivers) + IP generation notes and DESIGN.md
examples/nexys_video/   original Artix-7 top + Vivado project
usb-c/                  USB-C DP Alt Mode port: spec + FUSB302B/ESP32-S3
                        PD policy (recommended connector approach)
test_benches/           simulation suite
misc/                   C/python golden-model checkers and decoders
```

## Running the verification suite

Needs Icarus Verilog and a C compiler; see the testbench headers for the
exact compile lines (each `tb_*.v` documents its own defines). The frame
testbenches dump pre-scrambler symbol streams which
`misc/check_dp_frame.c` / `misc/check_dp_audio.c` verify independently.

The MIPI D-PHY backend has its own testbenches, each with its run command in
its header: `test_benches/test_dp_dphy_tx.sv` (the 10->16 gearbox, fully
self-contained) and `test_benches/test_transceiver_bank_dphy.sv` (the whole
PHY bank, using the behavioural D-PHY models in `test_benches/sim_models/`
and the Gowin GW5A simlib for the GSR cell).

## Heritage and thanks

The main-link datapath, AUX channel and link-training policy are Mike
Field's original work - this project stands on it. His original notes:

> This design has taken many hours - 3 months of work for the initial
> VHDL design, and another month or so to convert it to Verilog. If you
> want to say thanks either drop me an email, or how about PayPal to
> hamster@snap.net.nz?

The M/N timing values use his empirically-proven rounded-x0x80000 form
(exact small rationals are rejected by some sinks).
