// Build-configuration defines for the Tang Primer 25K D-PHY flow — 1080p60
// RBR x4 variant. Must be the FIRST entry in the .gprj file list.
//
// See gowin_defines.v for DP_VENDOR_DPHY / GOWIN_PLL_IP. DP_TP25K_1080P
// switches top_tang_primer_25k to 1920x1080p60 over 4 lanes (148.5 MHz pixel
// clock); a 4-lane sink path is required (pin assignment C/E and a 4-lane or
// native-DP sink).
`define DP_VENDOR_DPHY
`define GOWIN_PLL_IP
`define DP_TP25K_1080P
