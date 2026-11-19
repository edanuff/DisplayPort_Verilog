# DisplayPort over the Gowin hardened MIPI D-PHY

How and why `dp_transmitter` drives DisplayPort out of a Gowin GW5A part that
has no SERDES transceivers, using the hardened MIPI D-PHY TX as a raw
serializer. This is the design basis of `src/gowin/transceiver_bank_dphy.v`
and the `tang_primer_25k` example. It is hardware-proven (the a2fpga a2p25
board runs 4-lane RBR 1080p60 with audio over this chain).

## 1. The problem

Small Gowin Arora-V parts such as the **GW5A-25** (GW5A-LV25MG121) have no
GTR SERDES, so the SERDES-based DP PHY used on the GW5AT-60 / GW5AST-138 can
not be ported directly. Options considered and rejected:

- A protocol bridge chip (MIPI DSI → DP, e.g. ANX7625 / SN65DSI86):
  procurement risk and/or no isochronous audio path and ASSR-only sinks.
- A soft SERDES on generic LVDS I/O: DP RBR is 1.62 Gbps/lane; GW5A generic
  true-LVDS tops out around 1.25 Gbps — a ~30% out-of-spec overclock.
- **Hardened MIPI D-PHY TX as a raw 1.62 Gbps serializer** + external swing
  regeneration — selected, below.

## 2. The key insight

Gowin's Arora-V hardened D-PHY TX (UG296E) is **protocol-free**. The
`MIPI_DPHY` primitive is an 8:1/16:1 gearbox serializer plus pad drivers;
every byte on the wire — including, in normal MIPI use, D-PHY's own
SoT/sync/EoT — is supplied by the fabric, and the low-power (LP) states are
separate bit-banged pad ports that we simply never drive. Hold `HSTXD_VLD`
and the lane enables high and it emits a **continuous, arbitrary NRZ
bitstream** at up to 2.5 Gbps/lane (UG296E §4.1.2 Fig 4-1).

So the FPGA transmits **native DisplayPort RBR**, reusing the entire
`dp_transmitter` link layer (training, scrambler, 8b/10b, MSA, audio SDPs,
AUX), with the D-PHY hard macro replacing the SERDES at the bottom of the
stack. No protocol bridge chip; the external BOM is signal conditioning only.

## 3. Silicon facts (Gowin UG296E / UG985E)

| Fact | Value |
|---|---|
| D-PHY TX support | GW5A 15K/25K/60K (75K/138K are RX-only) |
| Max HS rate | 2.5 Gbps/lane |
| DP RBR 1.62 Gbps | in spec, ~35% headroom |
| DP HBR 2.7 Gbps | **out of spec — not supported** |
| Gearbox | 8:1 or 16:1; fabric byte clock = rate / 8 or / 16 |
| Fabric clock @ RBR, 16-bit | **101.25 MHz** (`tx_clk_o`) |
| TX PLL | dedicated D-PHY PLL; CLKIN 19–800 MHz |
| Continuous HS | fabric-controlled; no forced LP return |

The clock lane is unused for DP (embedded clock) and may be left disabled.

## 4. Lanes and rates: 1080p without HBR

HBR (2.7 Gbps) exceeds the D-PHY's 2.5 Gbps rating, so bandwidth for 1080p is
recovered with **lane count** instead:

| Config | Payload (post-8b/10b) | 1080p60 @24bpp (3.56 Gbps) | 720p60 @24bpp (1.78 Gbps) |
|---|---|---|---|
| RBR x2 | 2.59 Gbps | ✗ | ✓ (69% util) |
| **RBR x4** | **5.18 Gbps** | **✓ (69% util)** | ✓ |

The example ships both: 720p60 RBR x2 (default, widest sink compatibility)
and 1080p60 RBR x4. DP carries RGB at 6/8/10/12/16 bpc; the plan of record is
**8bpc/24bpp**, the mandatory DP baseline every sink accepts.

> **Sink gotcha for RBR x4:** USB-C→HDMI docks have two independent lane
> gates — the mux pin assignment (C/E = 4-lane) *and* the DP→HDMI converter
> chip's own DPCD `MAX_LANE_COUNT`. Many "1080p" dongles use 2-lane
> converters that cover 1080p60 at HBR for a normal source but not at RBR.
> Prefer video-only USB-C→HDMI adapters (pin assignment C/E by
> construction), 4K60/HDMI-2.0-rated converters, passive USB-C→DP cables, or
> native-DP sinks. Read `MAX_LANE_COUNT` over AUX to qualify a sink.

## 5. Signal chain

```
GW5A fabric                                   (carrier board)
+--------------------------+
| dp_transmitter link layer|
|  LT / scrambler / 8b10b  |
|  MSA / audio SDPs        |
+-----------+--------------+
            | 80-bit symbol bus @ 81 MHz (4 lanes)
+-----------v--------------+   transceiver_bank_dphy
| 8b10b x4 -> async FIFO   |   (81 -> 101.25 MHz, lane map/polarity)
| -> dp_dphy_tx 10->16 GB  |
| -> MIPI_DPHY hard TX     |   ~280-540 mVpp diff (SLVS), 1.62 Gbps NRZ
+-----------+--------------+
          ==+== AC caps (one per leg)
+-----------v--------------+
| DP redriver (SN75DP130)  |   swing/pre-emphasis REGENERATION + LT response
+-----------+--------------+
            v
   USB-C mux / DP connector  (see usb-c/ for the Alt Mode stack)

AUX : FPGA LVDS25 pair + bias/pulldown network (src/dp_aux_pad.sv), routed
      THROUGH the redriver's AUX pass-through (keeps its training auto-mode)
HPD : a level into dp_transmitter.hpd (USB-C Alt Mode: reconstructed from
      PD Status/Attention VDMs by an MCU; native DP: the jack's HPD pin)
```

### Why a regenerating redriver

The D-PHY pads emit MIPI SLVS levels — ~280–540 mVpp differential, roughly DP
swing level 0 — legal but with zero headroom and no way to honor a sink's
swing/pre-emphasis requests during link training. A **linear** redriver only
tracks input amplitude, so it cannot fix this. A **regenerating** redriver
(TI SN75DP130, DP 1.1a/1.2, HBR2, 4-lane) instead restores the full DP level
set (programmable VOD 340/510/690/1000 mVpp + pre-emphasis) independent of
input amplitude, responds to training (auto, snooping AUX, or manual over
I2C), and its input squelch holds the main-link outputs off while the D-PHY
lanes are quiet — a correct dead-link-before-training to the sink. It adds
only ~15 ps jitter and is cheap and widely stocked. (It does not clean jitter
— it is a redriver, not a retimer; the RBR jitter budget is generous.)

## 6. The gateware shim

`dp_transmitter`'s `DP_VENDOR_DPHY` branch exports the pre-8b/10b symbol
stream (`ext_tx_symbols`) and takes back the symbol clock
(`ext_symbol_clk`); the board top hosts `transceiver_bank_dphy` because the
D-PHY pads are `inout` macro ports. That bank:

1. **8b/10b-encodes** 4 lanes in the 81 MHz symbol domain
   (`lane_encoder_8b10b`), because DP link training (TPS2) needs per-symbol
   disparity forcing.
2. **CDC** 81 → 101.25 MHz through a small gray-coded async FIFO (both clocks
   come from one VCO at a fixed 4:5 ratio, so the FIFO only absorbs phase and
   the 4-of-5 pull pattern; its level is constant in steady state).
3. **10 → 16 regearing** (`dp_dphy_tx`): one shared lockstep gearbox packs
   10-bit symbols into the D-PHY's 16-bit gearbox words, LSB-first per
   UG296E's byte ordering (lower 8 bits sent first). Pulls one 20-bit symbol
   pair per lane in 4 of every 5 clocks over an LCM-80 rolling buffer.
4. **Lane map / polarity** (`REVERSE_LANES` / `LANE_MAP` / `POL_INV`): a
   carrier may route DP lane n from any D-PHY data lane with either polarity;
   encode the PCB's actual routing here. There is no inversion or remap
   anywhere else in the chain (the D-PHY TX has no invert, and DP training
   does not fix polarity), so **P/N and lane order are layout-owned** — verify
   them against the module schematic before fab.
5. **Enable sequencing**: `txdpen` before `hstxen` (UG296E Fig 4-1), on
   settle timers (the generated PLL wrapper leaves `lock` dangling).

## 7. Clocking — no new oscillators

The D-PHY TX PLL takes a `clkin` (19–800 MHz) from the fabric and does all
high-speed multiplication; **VCO must be an integer multiple of CLKIN**. The
example uses 54 MHz → VCO 810 (×15): the four serializer phases on CLKOUT0–3
and the 81 MHz link-symbol clock on CLKOUT4 (÷10). `tx_clk_o` (101.25 MHz) is
a PLL output. The pixel clock is generated inside `dp_transmitter` from the
81 MHz symbol clock (DP synchronous clocking) — 81 × 11 / 12 = 74.25 MHz
(720p) or / 6 = 148.5 MHz (1080p), VCO 891. DP needs only ±300 ppm, so any
crystal clears the reference requirement. There is no SSC (the D-PHY PLL has
none; SSC is optional in DP). Never inject a fabric-synthesized high-speed
clock.

## 8. Board requirements (summary)

- Route the D-PHY data quad as 100 Ω differential pairs; **intra-pair** skew
  tight (the SLVS-swing segment FPGA→redriver is the fragile one). Do **not**
  lane-to-lane match — the sink deskews multiple UI, and DP even permits
  deliberate TX lane skew.
- **AC-couple every main-link leg** (one cap per leg), placed near the
  receiving device, symmetric per pair.
- Keep the FPGA→redriver segment short/low-loss: the D-PHY's worst-case swing
  (~0.28 Vpp) is close to the redriver's minimum input (0.3 Vpp); input EQ is
  the recovery knob.
- AUX: the proven FPGA-side network (series resistors + the DP-spec
  asymmetric bias for source detection; **no RX inverter**), AC-coupled into
  the redriver's AUX_SRC, with a single 100 kΩ bias pair on the sink side.

## 9. Risks

| Risk | Mitigation |
|---|---|
| D-PHY TX jitter vs the DP RBR budget | RBR budget is generous; measure with symbol-error soaks. A retimer is the escape hatch (not expected). |
| Continuous-HS assumption | Scope an unbroken 8b/10b stream for LP excursions / gearbox hiccups as the first bring-up step. |
| D-PHY bit/byte ordering vs 8b/10b symbol order | Verified bit-exact in simulation (`test_dp_dphy_tx`, `test_transceiver_bank_dphy`); confirm against a captured RBR stream at bring-up. |
| Strict converters at RBR | The redriver supplies real swing/PE levels; qualify sinks by DPCD `MAX_LANE_COUNT`. |

## 10. References

- Gowin **UG296E** — Arora V Hardened MIPI D-PHY User Guide.
- Gowin **UG985E** — GW5A-25 pinout (M0 quad, MIPI rails).
- TI **SN75DP130** datasheet (SLLSE57E) — VOD/PE, squelch, AUX auto-config.
