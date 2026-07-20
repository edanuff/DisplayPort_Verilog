# a2-mega carrier — DisplayPort TX gateware configuration

Board-specific build of `dp_transmitter` for the a2-mega carrier
(Tang Mega **60K** SOM, GW5AT-LV60PG484). Same RTL as
[`examples/tang_mega`](../tang_mega/); what differs is the copper/gateware
contract, which this project's generated SERDES IP and defines implement.

## Die-true lane contract (record kept on the board schematic too)

The Tang Mega SOM PCB uses 138K-convention net names; on the GW5AT-60 die,
Q0 lanes 1 and 3 swap ball positions. In die-true terms the carrier wires:

| TUSB1046A input | die lane | pair polarity |
|---|---|---|
| DP0 (ML0) | Q0 lane 3 | inverted |
| DP1 (ML1) | Q0 lane 2 | inverted |
| DP2 | Q0 lane 1 | inverted (future 4-lane) |
| DP3 | Q0 lane 0 | not inverted — verify before 4-lane use |

Refclk: DSC1103 135 MHz LVDS XO on **Q0_REFCLK1** (AC-coupled).

## IP configuration (Customized PHY, IPUG1024)

As `examples/tang_mega` except: **lanes 2+3** bonded (master lane 2),
**REFCLK1**, **tx_pol_invert on both lanes**. Everything else identical:
TX only, QPLL0, 2.7 Gbps, width 20 raw (8B10B off), DRP on, read start
depths 16, 420 mV, FFE flat. `gowin_defines.v` sets `DP_SERDES_LANES_23`,
which selects the ML0→lane3 / ML1→lane2 hookup in
`transceiver_bank_gowin.v`. The `.csr` sidecar is registered via
`a2_mega_dp.gprj.user` (P&R errors with CM2031 without it).

## Build

```
cd examples/a2_mega
echo 'open_project a2_mega_dp.gprj
run all
exit' | /Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin/gw_sh
```

Verified result (Gowin V1.9.12.02 SP2): timing closed, 0 violated
endpoints, TNS 0.000 all clocks; clk_sym 135.375/135.007 MHz (constraint
anchored on LANE2, the bonding master), clk100 107.5/100, bitstream
generated; 2909 LUT (5%), 2343 FF (4%) — matching the tang_mega baseline.

A future 138K-SOM variant of the same carrier needs its own IP run
(lanes 1+2, master lane 1, same inversions, REFCLK1) plus a matching
wrapper branch — see the Tang Mega README's lane-permutation note.
