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
places and routes the complete transmitter with `synth_check_top.sv`,
including the generated `dp_serdes` GTR12 IP (src/serdes/) and the PLLA
clock wrappers - the real 1080p60/HBR clock topology. Build with the
pipe method:

```
cd examples/tang_mega
echo 'open_project tang_mega_dp.gprj
run all
exit' | /Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin/gw_sh
```

Result (Gowin V1.9.12.02 SP2): **timing closed, 0 violated endpoints,
TNS 0.000, bitstream generated** - clk100 109.4/100 MHz, clk_sym
136.9/135 MHz, clk_pix 180.3/148.5 MHz, worst setup slack +0.103 ns;
utilization 2881 LUT (5%), 2343 FF (4%), 13 BSRAM (12%). If clk_sym
margin ever tightens, the next lever is one more pipeline stage in the
SDP engine's wire-byte mux.

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
- DRP port enabled (future link-training-driven swing/FFE via exported
  "TX AFE" `.csr` write sequences); Vdiffpp **420 mV** (DP level 0 +5%),
  FFE flat (Cm=0, C0=40, C1=0), TX bonding master = Q0 Lane0

Keep the generated `serdes.v` / `Customized_PHY_Top` **and the
`serdes.toml` / `.csr` sidecars** in the project — the sidecars carry most
of the configuration. Match the port names in
`src/gowin/transceiver_bank_gowin.v` (`GOWIN_SERDES_IP` branch) to the
generated wrapper.

The two fabric PLLs are hand-instantiated PLLA wrappers in
`src/gowin/gowin_plls.v` (`gowin_mgmt_pll`: 50 MHz osc x24 VCO /12 =
100 MHz for AUX timing; `gowin_pixel_pll`: 135 MHz x44/5 VCO /8 =
148.5 MHz pixel clock); regenerate in the IP GUI if the PLLA
boilerplate changes across IDE versions.

The TX fabric clock is `tx_pcs_clkout` = line rate / 20 = **135 MHz**
at HBR, shared by both lanes; it is the design's `tx_symbol_clk`.

## Build defines

`DP_VENDOR_GOWIN` + `GOWIN_SERDES_IP` + `GOWIN_PLL_IP` for hardware;
`DP_VENDOR_GOWIN` alone gives the behavioural-stub configuration used by
the simulations.

## USB-C output (DP Alt Mode + USB 2.0)

Target connector topology: a single USB-C receptacle carrying DP Alt Mode
video plus USB 2.0 from an on-board MCU.

**Recommended approach: the scoped FUSB302B + ESP32-S3 design in
[`usb-c/`](../../usb-c/).** PD and Alt Mode policy run as ~1.1k lines of
portable, tested C on the ESP32-S3 (which also provides the USB 2.0
host/device function), with the FUSB302B as the CC PHY and the
TUSB1046A-DCI as the lane/AUX crosspoint. See
[`usb-c/SPEC.md`](../../usb-c/SPEC.md) for the complete port
specification - roles, power policy, VDM sequence, TUSB1046A control
truth table, HPD translation, and detach behavior - and
[`usb-c/README.md`](../../usb-c/README.md) for the integration contract.

```
                     +-------------------+
 FPGA DP lanes ----->|                   |----> USB-C SS pairs (all four)
 FPGA AUX (2 GPIO) ->|  TUSB1046A-DCI    |----> SBU1/SBU2
                     +-------------------+
                        ^ FLIP/CTL0/CTL1/HPDIN
                        |
 FPGA HPD/DP-enable <-- ESP32-S3 <--I2C/INT--> FUSB302B <--> CC1/CC2
 (usb-c/rtl bridge      |    |
  optional)             |    +--> VBUS 5 V source switch (existing
                        |         board path, hardware current limit)
 MCU USB 2.0 D+/D- -----+--- ESD ---> A6+B6 / A7+B7 (tied pairs)
```

Key properties (details in SPEC.md):

- 5 V only, one fixed Source PDO (5 V/1 A, Rp at default USB current;
  sized for a small bus-powered hub with a DP-to-HDMI bridge - larger
  docks need a powered hub; SPEC.md documents how to change the
  budget); the board's hardware current limiter stays authoritative;
  power/data roles are paired at attach and all swaps are rejected
- Device mode (attached to a PC): non-PD sink, ESP32-S3 USB device;
  the board may be bus-powered from the host's 500 mA in this mode
  (programming/debug posture - DP and SERDES are off by design)
- Host mode (attached to a monitor): 5 V source, USB host, DP Alt Mode
  entered via the standard VDM ladder, pin assignment C (four pairs to
  DP; the FPGA still trains its two-lane link inside them)
- HPD is reconstructed from DP Status/Attention VDMs by the ESP32 and
  delivered to `dp_transmitter.hpd` (optionally through
  `usb-c/rtl/usbc_dp_control.sv`, which generates the timed IRQ pulse
  for the parameterized `hotplug_decode`)
- Out of scope by design: monitors/docks that insist on powering the
  board (Rp-presenting chargers), pin assignment D-only sinks, active
  or electronically marked cables, USB3/USB4

### Alternative: autonomous PD controller

Implementors who prefer PD to live entirely in silicon - no PD firmware
on the MCU, USB-C negotiation independent of MCU health - can use a
stand-alone Alt-Mode-capable PD controller such as the TI **TPS65987D**
(or dual-port TPS65988) driving the same TUSB1046A and HPD wiring. The
part is NRND but well documented (TRM + app note SLVA844 "TPS6598x
DisplayPort Alternate Mode", TIDA-050012/050014 reference designs) and
was validated as expressible for this exact topology: DFP_D source,
pin assignments C/D/E, single 5 V PDO, GPIO events for mux control and
HPD, configuration via the TPS6598x Application Customization Tool
into an SPI flash. Note that the TPS25750/TPS25751/TPS26750 do NOT
support Alt Mode and cannot be substituted. The detailed configuration
is left as an exercise for the implementor.

## References

- IPUG1024E (Customized PHY), IPUG1043E (EDP PHY), IPUG1179E (EDP
  encoder/decoder) — Gowin
- github.com/key2/gowin-serdes — direct GTR12 instantiation reference
- github.com/sipeed/TangMega-138KPro-example — board-proven SERDES configs
