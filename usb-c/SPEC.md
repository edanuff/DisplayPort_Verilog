# USB-C, USB 2.0, and DisplayPort Alt Mode Port Specification

## 1. Purpose

This directory specifies a single USB-C receptacle that combines:

- USB 2.0 host or device operation from an ESP32-S3;
- DisplayPort source operation from the FPGA in this repository;
- CC and USB PD signaling through an FUSB302B; and
- DisplayPort lane and AUX orientation through a TUSB1046A-DCI.

The board is deliberately not a general-purpose USB Power Delivery product.
It operates at 5 V only and sources at most 1 A. The existing board power
path provides the electrical current limit; firmware must never advertise more
than that limit. The budget is sized to run a small bus-powered hub with a
built-in DP-to-HDMI bridge; users with larger docks or downstream loads are
directed to a powered hub.

The FUSB302B is not a VBUS power switch. The board retains its external 5 V
source switch/current limiter and reverse-current blocking. `VBUS_ENABLE` from
the ESP32 may only control that protected 5 V path. The FUSB302B connects to
CC1/CC2, I2C, `INT_N`, and VBUS sensing; it never controls a higher-voltage
rail. Connector VBUS and the board-facing sense/power path must retain the
board's existing 5 V protection.

## 2. Product roles

Power and USB data roles are paired and never swapped after attachment.

| Connection | CC/power role | USB data role | VBUS behavior | DisplayPort |
|---|---|---|---|---|
| PC or other USB host | Sink with Rd | UFP/device | Source switch off; the host's 5 V may power the board (section 3.2) | Off |
| USB 2.0 peripheral | Source with Rp at default USB current | DFP/host | Supply 5 V, maximum 1 A | Off |
| Bus-powered mini dock | Source with Rp at default USB current | DFP/host | Supply 5 V within the existing board envelope | On when DP Alt Mode is offered |
| Self-powered monitor presenting Rd | Source with Rp at default USB current | DFP/host | Nominal 5 V is present, but the monitor is not expected to use it as system power | On |

A USB-C connection is not electrically power-neutral: one end presents Rp and
places 5 V on VBUS, and the other presents Rd. In the monitor case the board is
the nominal 5 V Source even though it is not intended to power the monitor.

A monitor that presents Rp because it intends to power or charge its partner is
outside this specification. Supporting that topology would require the board to
attach as a power Sink and later become DFP through a data-role swap.

## 3. Power policy

Host/Source mode has exactly one advertised capability:

```text
Fixed Source PDO: 5.0 V, 1.0 A
Type-C Rp value:  default USB current (500 mA promise to non-PD sinks)
```

The Rp tier deliberately advertises less than the PDO: a non-PD sink may
draw whatever Rp promises without ever negotiating, so Rp must stay within
the budget's guaranteed-safe zone, while PD-capable sinks obtain the full
1 A through the negotiated contract.

The policy shall:

- accept only an RDO selecting PDO 1 with operating and maximum current no
  greater than the configured budget (1 A);
- reject `DR_SWAP`, `PR_SWAP`, and `VCONN_SWAP`;
- advertise no higher voltage, PPS, dual-role power, or data-role-swap
  capability;
- turn off the VBUS source switch on detach, fault, disable, and hard-reset
  recovery; and
- keep the board's hardware current limiter authoritative.

### Changing the source current budget

The budget is one number: `source_milliamps` in `usbc_port_default_config()`
(`src/usbc_port.c`), consumed in three places that stay consistent
automatically:

1. the advertised Source PDO current;
2. the RDO acceptance bound; and
3. the FUSB302 Rp tier, derived in `fusb302_set_source_current()`:
   below 1500 mA the port advertises default USB current, at 1500 mA it
   advertises the 1.5 A tier. (The 3 A tier is intentionally not
   implemented.)

To raise the budget: verify the board's 5 V source switch and hardware
current limiter genuinely support the new value with margin (the limiter
remains authoritative), set `source_milliamps`, rebuild, and re-run
`make -C usb-c check` (the encoding test bounds currents against the
configured budget). Do not raise Rp beyond a level the hardware can
sustain for a non-negotiating sink.

Device/Sink mode behaves as a non-PD USB 2.0 device. It presents Rd, leaves the
VBUS source switch off, waits for valid 5 V, and starts the ESP32-S3 USB device
function. It does not negotiate a Sink PDO and cannot request a voltage above
5 V.

### Reference VBUS power path

The two directional paths (validated on the a2-mega carrier):

- Source: 5 V rail -> TPS2553 current-limited switch -> VBUS. EN from an MCU
  GPIO with a 1 kOhm pull-down (off during every reset/boot window);
  R_ILIM = 23.7 kOhm sets a 1.0 A minimum / 1.17 A maximum limit matching the
  advertised PDO; 0.1 uF at IN; FAULT optional. On the ESP32-S3, IO46 is an
  ideal EN pin: its strapping constraint (must be low at reset) is identical
  to the Type-C requirement.
- Sink: VBUS -> polymer PTC (1.1 A hold, >=12 V, e.g. Bourns MF-PSML110/12) ->
  LM66100 ideal diode (CE tied low) -> 5 V rail. The diode blocks backfeed in
  host mode automatically; the PTC protects the diode's 1.5 A limit against
  3 A-capable hosts during a board fault. TVS on the connector VBUS node;
  a few uF bulk plus 0.1 uF on the node.

The paths never fight: in host mode VBUS sits below the rail by the switch
drop, which holds the ideal diode off.

General rule for nets shared with an unconfigured FPGA (which presents weak
pull-ups, spec'd as current: up to 400 uA strong tier on Gowin GW5A): 1 kOhm
pull-downs and 4.7 kOhm pull-ups guarantee valid logic levels against any
internal pull strength.

### Bus-powered device operation (programming and debug)

Device mode is the board's programming/debug posture, and the board may be
powered entirely from the host's VBUS in that mode - the expected budget is
the standard USB 2.0 envelope (5 V, 500 mA after enumeration; 2.5 W). This
works because DisplayPort is off by design in device mode: the SERDES never
powers up and the DP datapath idles, so the remaining system load must fit
(and in practice does fit) the 2.5 W envelope.

Board requirements for bus-powered operation:

- a sink-direction power path from connector VBUS onto the board's 5 V rail
  (ideal-diode/ORing against the self-power input, reverse-blocking in both
  directions, and never conducting while the source switch is on);
- FUSB302B dead-battery attach: an unpowered board presents Rd through the
  FUSB302B pull-downs, the host applies VBUS, the board boots from it, and
  the DRP toggle then resolves the already-attached sink state normally;
- host/source mode (sourcing 5 V/1 A to a monitor or hub) still requires the
  board's own supply; a bus-powered board with no host attached is simply
  off, so no contradictory state exists.

Optionally, firmware may measure the host's Rp advertisement through the
FUSB302B to distinguish 500 mA / 1.5 A / 3 A budgets; the scoped policy does
not require it.

## 4. USB 2.0 path

USB-C receptacle A6/B6 are joined as D+ and A7/B7 are joined as D- near the
connector. D+/D- bypass the TUSB1046A and connect through the board protection
network to the ESP32-S3 USB PHY.

USB 2.0 remains active while all four USB-C high-speed pairs are allocated to
DisplayPort. The existing ESP32-S3 host stack remains responsible for hub and
class-driver operation; this directory only selects host, device, or off.

## 5. DisplayPort path

The FPGA is always a DP source. The current Tang Mega configuration supplies
two HBR lanes. Connect FPGA lanes 0 and 1 to TUSB1046A DP inputs 0 and 1 -
or, when board routing prefers it, any permutation and per-pair P/N inversion
of the transceiver lanes: the GTR12 Customized PHY must then be generated to
match (bonded lane group selection and per-lane `tx_pol_invert`), and the
copper/gateware contract must be recorded on the schematic - in DIE-true
lane names, not carrier-label names. The a2-mega carrier (GW5AT-60 SOM) does
exactly this: DP0<-L3, DP1<-L2, DP2<-L1 (those three pairs P/N-inverted),
DP3<-L0 (not inverted; L0's polarity label on the Sipeed carrier sheet
contradicts the die pinout - verify before 4-lane use), refclk on
Q0_REFCLK1. Note the Tang Mega SOM PCB carries 138K-convention net names;
on the 60K die, lanes 1 and 3 swap ball positions relative to the 138K, so
carrier labels must be translated before configuring the PHY. The 2-lane
link therefore bonds lanes 3+2 with tx_pol_invert on both.

Connector-side AC coupling follows the TUSB1046A datasheet reference design
(Figures 27/28): capacitors on the TX1/TX2 pairs only. The RX1/RX2 pairs run
DC to the receptacle - in DP Alt Mode their blocking capacitors live at the
far end (the sink's USB TX caps) or inside a Type-C-to-DP adapter. Do not add
board caps to the RX pairs; in the C-to-C case that puts two capacitors in
series and drops below DisplayPort's 75 nF minimum.

Because USB 3.x is not implemented, DP Alt Mode selects pin assignment C and
puts the TUSB1046A in its four-pair DP configuration. Allocating four Type-C
pairs does not require the DP main link to train four lanes: the existing FPGA
link manager still selects a two-lane main link through DPCD link training.

The DP AUX source-side electrical interface, AC coupling, and bias network must
be implemented between the FPGA board-level AUX buffer and the TUSB1046A AUX
pins. SBU1/SBU2 connect only through the TUSB1046A AUX switch.

## 6. TUSB1046A control

I2C mode is the recommended control method (used by the a2-mega carrier):

- `I2C_EN` pulled to 3.3 V through 1 kOhm; `SSEQ0/A0` and `DPEQ0/A1` left
  floating, giving 7-bit address 0x12 on the same bus as the FUSB302B (0x22).
- Pins 23 (`CTL1/HPDIN`), 29, and 32 are no-connects. In I2C mode pin 23 is
  an HPD input with an internal 500 kOhm pull-down; firmware sets
  `HPDIN_OVRRIDE` (General register 0x0A bit 3) so the pin is ignored -
  HPD originates in the ESP32 anyway, so the wire adds nothing.
- To enable DP after DP Configure is ACKed and HPD is high, write register
  0x0A with `CTLSEL[1:0]=10` (four-lane DP), `FLIPSEL` per cable orientation,
  and `HPDIN_OVRRIDE=1`. On HPD low, mode exit, or detach, write `CTLSEL=01`
  (USB3-only default, DP lanes off). Receiver EQ is register-settable
  (`DPxEQ_SEL`) instead of strap resistors.
- AUX snooping (on by default) watches DPCD `LANE_COUNT_SET` and
  `SET_POWER_STATE` writes and trims the active lanes to what the FPGA's
  link training negotiates - no firmware involvement.

### Alternative: GPIO-mode control

`I2C_EN` is strapped low. The ESP32 drives:

| Signal | Inactive/device/USB2-only | DP active |
|---|---:|---:|
| `CTL1` | 0 | 1 |
| `CTL0` | 0 | 0 |
| `FLIP` | don't care | 0 for CC1, 1 for CC2 |
| GPIO-mode `HPDIN` | 0 | Remote HPD level from DP Status/Attention |

At TUSB1046A power-up, pulse `CTL0` high and then low while `CTL1` is low to
leave the device's default USB3 state and enter power-down mode. `CTL1=1` and
`CTL0=0` selects the four-lane DP C/E routing described by the
[TUSB1046A datasheet](https://www.ti.com/lit/ds/symlink/tusb1046a-dci.pdf).

## 7. FUSB302B and PD behavior

The FUSB302B performs autonomous DRP toggle and reports whether it stopped as
Source or Sink and whether CC1 or CC2 is active. Firmware then changes to the
corresponding attached configuration.

In Source mode firmware enables the 5 V switch, waits for VBUS valid, enables
the FUSB302 PD receiver and advertises the single Source PDO. The FUSB302
hardware generates and checks CRC, sends GoodCRC, and retries transmissions;
the ESP32 owns the Type-C, PD, and Alt Mode policy. This division follows the
[FUSB302B datasheet](https://www.onsemi.com/pdf/datasheet/fusb302b-d.pdf).

After accepting a valid Request, the source sends `Accept` and `PS_RDY`, then
runs this structured VDM sequence:

1. Discover Identity;
2. Discover SVIDs and locate `0xFF01`;
3. Discover DisplayPort Modes and locate a sink mode supporting pin C;
4. Enter Mode;
5. DP Status;
6. DP Configure for pin C, DP signaling, partner UFP_D; and
7. process subsequent DP Attention messages.

If the partner has no DisplayPort SVID/mode or declines the sequence, USB 2.0
host operation remains active and the DP path stays off.

The PD contract (steps through `PS_RDY`) is time-bound and must complete
regardless of FPGA state. The VDM ladder is not: firmware should gate step 1
on an FPGA-ready indication (configuration done), since alt mode entry has no
deadline and DP is useless until the FPGA can train. A monitor attached at
cold boot simply enters DP a moment later.

This subset intentionally omits cable SOP'/SOP'' discovery, electronically
marked/active cable policy, USB3, USB4, Thunderbolt, PPS, higher-voltage PDOs,
and DP sink operation.

## 8. HPD translation

USB-C has no physical DP HPD pin. The monitor supplies HPD level and IRQ in DP
Status and Attention VDOs. The ESP32 must deliver the reconstructed HPD level
to the FPGA `dp_transmitter` HPD input - either on a dedicated GPIO or as a
message over an existing ESP32-to-FPGA link, with the FPGA (optionally via
`rtl/usbc_dp_control.sv`) regenerating the timed IRQ pulse. In TUSB1046A I2C
mode no HPD wire to the mux exists; DP enable/disable is done through register
0x0A (section 6). In GPIO mode the mux's `HPDIN` pin must also be driven.

An HPD IRQ must become a 0.5-1.0 ms nominal low pulse on the DP-source side.
The repository's `hotplug_decode` uses parameterized 0.5 ms IRQ and 2 ms
disconnect thresholds. The optional `rtl/usbc_dp_control.sv` defaults to a
0.75 ms pulse. Alternatively, the ESP32 can produce the timed pulse directly.

## 9. FPGA responsibility

No USB-C, CC, or PD state machine is required in the FPGA. FPGA responsibilities
are limited to:

- remain reset or disabled until DP Configure is acknowledged;
- consume the reconstructed HPD level/IRQ;
- perform normal AUX transactions, EDID/DPCD access, and DP link training; and
- transmit the existing two-lane DP main link.

The optional bridge module only synchronizes the ESP32 control GPIOs, gates DP
reset, and generates the HPD IRQ pulse expected by the existing decoder.

## 10. Reset and detach behavior

On detach or fault, firmware performs these actions in order:

1. drive FPGA HPD low and disable/reset the DP source;
2. disable DP in the TUSB1046A (I2C mode: write `CTLSEL=01`; GPIO mode:
   drive `CTL1` low and `HPDIN` low);
3. stop the ESP32 USB host/device stack;
4. disable the 5 V VBUS source; and
5. return the FUSB302B to autonomous DRP toggle.

On a received PD hard reset while sourcing, the example disables DP and USB,
turns VBUS off for the configured source-recovery interval (750 ms by default),
restores 5 V, and restarts the single-PDO Source negotiation.

## 11. Source references

- [onsemi FUSB302B datasheet](https://www.onsemi.com/pdf/datasheet/fusb302b-d.pdf)
- [TI TUSB1046A-DCI datasheet](https://www.ti.com/lit/ds/symlink/tusb1046a-dci.pdf)
- [TI TUSB1046 EVM guide and schematic](https://www.ti.com/lit/ug/sllu255a/sllu255a.pdf)
- [ChromiumOS EC USB-C/PD implementation overview](https://chromium.googlesource.com/chromiumos/platform/ec/+/HEAD/docs/usb-c.md)
- [ChromiumOS EC DP Alt Mode sequence](https://chromium.googlesource.com/chromiumos/platform/ec/+/HEAD/docs/usb-tcpmv2.md)
