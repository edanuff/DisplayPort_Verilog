// Build-configuration defines for the Tang Primer 25K D-PHY flow. This file
// must be the FIRST entry in the .gprj file list so the defines apply to the
// whole compilation unit.
//
// DP_VENDOR_DPHY : dp_transmitter exports the pre-8b/10b symbol stream to the
//                  board's transceiver_bank_dphy (the GW5A-25 hardened MIPI
//                  D-PHY used as a raw serializer) instead of an on-chip SERDES.
// GOWIN_PLL_IP   : the pixel clock comes from gowin_pixel_pll, fed by the
//                  81 MHz symbol clock (DP synchronous clocking).
//
// This is the baseline 720p60 RBR x2 configuration. For 1080p60 RBR x4 use
// gowin_defines_1080p.v instead (adds DP_TP25K_1080P).
`define DP_VENDOR_DPHY
`define GOWIN_PLL_IP
