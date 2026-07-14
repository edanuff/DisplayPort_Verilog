# DisplayPort_Verilog

An open-source Verilog implementation of a DisplayPort source (transmitter)
for FPGAs, with **audio support**, released under the MIT License.

Originally written by Mike Field (hamster) for the Xilinx Artix-7 (Digilent
Nexys Video); since restructured into a self-contained, instantiable
`dp_transmitter` module with an ergonomic interface modelled on the
hdl-util HDMI core, targeting **Gowin GW5AT (Arora V)** parts with GTR12
transceivers as the primary platform, with the original Artix-7 support
retained under `examples/`.

## The module

```systemverilog
dp_transmitter #(
    .LANE_COUNT      (2),        // 1 or 2
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

**Fully verified in simulation; hardware bring-up not yet attempted.**
Every layer is gated by Icarus Verilog testbenches with *independent*
C-model checkers (`misc/`):

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

Synthesizability and sizing are checked with Yosys (`synth_gowin`):
roughly 800 LUTs for the TU packer, 800 for the SDP engine, 80 per lane
for 8b/10b, and 6 BSRAMs for the pixel FIFO.

## Layout

```
src/dp_transmitter.sv   the top-level module
src/core/               main-link datapath (idle/scrambler/training/skew)
src/video/              timing generator, CDC FIFO, TU packer, MSA
src/audio/              sample buffer, Maud measurement, SDP engine
src/auxch/              AUX channel, EDID/DPCD, link training policy
src/gowin/              GW5AT platform: fabric 8b/10b, SERDES bank
src/artix7/             original GTP transceiver bank (legacy)
src/test_streams/       hamster's hand-coded test sources (regression)
examples/tang_mega/     GW5AT board top + SERDES IP generation notes
examples/nexys_video/   original Artix-7 top + Vivado project
test_benches/           simulation suite
misc/                   C/python golden-model checkers and decoders
```

## Running the verification suite

Needs Icarus Verilog and a C compiler; see the testbench headers for the
exact compile lines (each `tb_*.v` documents its own defines). The frame
testbenches dump pre-scrambler symbol streams which
`misc/check_dp_frame.c` / `misc/check_dp_audio.c` verify independently.

## Heritage and thanks

The main-link datapath, AUX channel and link-training policy are Mike
Field's original work - this project stands on it. His original notes:

> This design has taken many hours - 3 months of work for the initial
> VHDL design, and another month or so to convert it to Verilog. If you
> want to say thanks either drop me an email, or how about PayPal to
> hamster@snap.net.nz?

The M/N timing values use his empirically-proven rounded-x0x80000 form
(exact small rationals are rejected by some sinks).
