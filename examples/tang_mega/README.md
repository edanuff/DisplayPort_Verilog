# Tang Mega (GW5AT) example — DisplayPort TX with audio

Example board top for `dp_transmitter` on Gowin Arora-V parts with GTR12
transceivers (Tang Mega 138K Pro: GW5AST-138, 2 quads; Tang Mega 60K:
GW5AT-60, 1 quad).

**Status: simulation-verified design; hardware bring-up not yet attempted.**
Everything below the SERDES is fully verified in simulation (see
`test_benches/`); the notes here capture what the Gowin documentation and
reference projects establish about the physical layer.

## Board reality check

Neither stock Sipeed dock has a DisplayPort receptacle. Transceiver lanes
are exposed on the PCIe slot (138K Pro: x4 + 2x SFP+; 60K: PCIe 2.0 x1).
Driving a real DP sink needs a PCIe-slot breakout to a DP plug with
AC-coupling per the DP spec, plus GPIO wiring for AUX (pseudo-differential
pair with the required bias network) and HPD.

## Timing viability (verified)

`tang_mega_dp.gprj` is a full Gowin EDA project (GW5AT-LV60PG484) that
places and routes the complete transmitter with `synth_check_top.sv` -
clocks arrive on input pins at the production 1080p60/HBR rates since
the SERDES/PLL IP is not yet generated. Build with the pipe method:

```
cd examples/tang_mega
echo 'open_project tang_mega_dp.gprj
run all
exit' | /Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin/gw_sh
```

Result (Gowin V1.9.12.02 SP2): **timing closed, 0 violated endpoints,
TNS 0.000** - clk100 101.5/100 MHz, clk_sym 137.1/135 MHz, clk_pix
183.4/148.5 MHz; utilization 2655 LUT (5%), 2205 FF (4%), 13 BSRAM
(12%). The real clocks (SERDES word clock, PLL pixel clock) use
dedicated clock routing, so this pin-clocked result is conservative.
If clk_sym margin ever tightens, the next lever is one more pipeline
stage in the SDP engine's wire-byte mux.

## SERDES IP generation (Gowin EDA IP Core Generator)

Generate a **Customized PHY** (IPUG1024) with:

- Protocol: Customized, **TX only**, 2 lanes, **channel bonding**, QPLL
- Line rate **2.7 Gbps** (DP HBR, the 1080p60 production mode; 1.62
  RBR for the 720p fallback), refclk **135 MHz**
  (program the on-board MS5351 clock generator; 138K Pro controls it via
  the onboard UART — see Sipeed wiki)
- Internal data width **20**, external ratio 1:1 (fabric width 20)
- **8B10B encoding OFF** (raw mode) — encoding is done in fabric by
  `src/gowin/lane_encoder_8b10b.v`, because DP link training (TPS2)
  requires per-character disparity forcing which the GTR12 hard PCS does
  not expose
- Optional: enable the **DRP port** and export `.csr` write sequences for
  "TX AFE" (swing / FFE) if you want link-training-driven drive levels;
  otherwise set Vdiffpp 400 mV, FFE flat, and rely on max-swing-reached
  DPCD replies

Keep the generated `serdes.v` / `Customized_PHY_Top` **and the
`serdes.toml` / `.csr` sidecars** in the project — the sidecars carry most
of the configuration. Match the port names in
`src/gowin/transceiver_bank_gowin.v` (`GOWIN_SERDES_IP` branch) to the
generated wrapper.

Also generate two fabric PLLs (`gowin_mgmt_pll`: board osc → 100 MHz for
the AUX timing; `gowin_pixel_pll`: 81 MHz word clock × 11/12 → 74.25 MHz
pixel clock).

The TX fabric clock is `tx_pcs_clkout` = line rate / 20 = **81 MHz**,
shared by both lanes; it is the design's `tx_symbol_clk`.

## Build defines

`DP_VENDOR_GOWIN` + `GOWIN_SERDES_IP` + `GOWIN_PLL_IP` for hardware;
`DP_VENDOR_GOWIN` alone gives the behavioural-stub configuration used by
the simulations.

## USB-C output (DP Alt Mode + USB 2.0)

Target connector topology: a single USB-C receptacle carrying DP Alt Mode
video plus USB 2.0 from an on-board MCU.

```
                     +-------------------+
 FPGA DP lanes ----->|                   |----> USB-C SS pairs (TX1/RX1/TX2/RX2)
 FPGA AUX (2 GPIO) ->|  TUSB1046A-DCI    |----> SBU1/SBU2
                     |  (linear redriver |
      orientation -->|  + crosspoint)    |
      + config       +-------------------+
                              ^
                              | CTL/I2C
 FPGA HPD (GPIO) <---+--------+----------+
                     |   PD controller   |<---> CC1/CC2  (attach, orientation,
 MCU (I2C, opt.) <-->|   (e.g. TPS25750/ |       PD, Enter DP Alt Mode,
                     |    TPS65983)      |       HPD via Status/Attention VDMs)
                     +-------------------+----> VBUS source switch (5 V out)

 MCU USB 2.0 D+/D- -------- ESD ------------> A6+B6 / A7+B7 (tied pairs)
```

Division of labour:

- **TUSB1046A-DCI**: routes the DP lanes onto the connector's high-speed
  pairs, un-flips plug orientation, applies the negotiated pin
  assignment, and muxes the AUX channel onto SBU1/SBU2. Pure analog -
  it must be *told* orientation and mode by the PD controller.
- **PD controller**: everything protocol-side. Detects attach and
  orientation on CC, sources VBUS (we are the DFP/source), runs the
  Discover/Enter Mode exchange for the DisplayPort SVID, sends DP
  Configure, drives the 1046's control pins, and converts the sink's
  DP Status/Attention messages into a local **HPD GPIO for the FPGA**
  (there is no HPD wire on USB-C). HPD asserts only after the full PD
  negotiation, which the design already tolerates - it idles until HPD.
- **USB 2.0**: D+/D- have dedicated connector pins present in both
  orientations (A6/A7, B6/B7). Tie A6-B6 and A7-B7 at the receptacle,
  add ESD protection, wire to the MCU. No mux, no interaction with the
  1046 or with DP lane count - DP can use all four SS pairs (pin
  assignment C/E, keeping 4-lane open) while USB 2.0 runs.

### Port operating modes (chosen design)

One USB-C receptacle, dual-role (DRP), two modes that both fall out of
a single standard attach resolution - no role swaps required, because
data role, power role and Alt Mode stay naturally aligned:

| | Far end | Our PD role | VBUS | MCU USB role | DP |
|---|---|---|---|---|---|
| **Device mode** | PC | sink / UFP | in (from PC) | device | none - Alt Mode never entered, FPGA HPD stays low, dp_transmitter idles |
| **Host mode** | monitor / dock | source / DFP | out (we supply 5 V) | host (to the monitor's hub) | Alt Mode entered, HPD asserts, link trains |

Configuration notes for this scheme:

- PD controller: DRP with **Try.SNK** (against a DRP-capable PC we bias
  to sink/device; monitors are sink-only so we always resolve source
  against them). DP source capability advertised in the DFP case only.
- The **MCU must have dual-role (OTG/DRD) USB 2.0** and needs to learn
  the resolved role from the PD controller - a data-role GPIO or an
  I2C status poll - to start the matching stack. Host role and
  VBUS-sourcing always coincide, so no separate host-VBUS switch is
  needed beyond the port's source path.
- VBUS path must be bidirectional at the board level: a sourcing
  switch (5 V out, PD-controller gated) and tolerance of applied VBUS
  when attached to a PC (board is otherwise self-powered).
- The FPGA is identical in both modes: everything is gated by the HPD
  GPIO from the PD controller, which only ever asserts in host mode
  after Alt Mode configuration completes.

RTL impact of all of this: none beyond what exists. HPD arrives as a
GPIO level with IRQ pulses (hotplug_decode already handles both), AUX
is unchanged, and any board-routing P/N swaps on the lanes are fixed
with the GTR12's static TX polarity-invert option. Plan the PD
controller configuration (straps/EEPROM, or the MCU as its I2C master)
as its own bring-up workstream - it is the largest piece of the
connector-side puzzle.

## References

- IPUG1024E (Customized PHY), IPUG1043E (EDP PHY), IPUG1179E (EDP
  encoder/decoder) — Gowin
- github.com/key2/gowin-serdes — direct GTR12 instantiation reference
- github.com/sipeed/TangMega-138KPro-example — board-proven SERDES configs
