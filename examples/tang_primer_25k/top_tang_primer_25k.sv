///////////////////////////////////////////////////////////////////////////////
// top_tang_primer_25k.sv : Example board top for the Sipeed Tang Primer 25K
//                          (Gowin GW5A-LV25MG121, "GW5A-25")
//
// Part of the DisplayPort_Verilog project.
//
// The GW5A-25 has NO SERDES/GTR transceivers, so this example drives
// DisplayPort over the part's hardened MIPI D-PHY used as a raw NRZ
// serializer (DP_VENDOR_DPHY): the entire dp_transmitter link layer is
// reused unchanged and transceiver_bank_dphy replaces the SERDES bank at
// the bottom of the stack. See README.md in this directory for the design
// rationale, the D-PHY IP generation steps, and the external analog chain
// (AC coupling + an SN75DP130 swing/pre-emphasis regenerator).
//
// Default configuration: 1280x720p60 RGB over RBR (1.62 Gbps) x 2 lanes,
// 48 kHz stereo audio. Define DP_TP25K_1080P for 1920x1080p60 over RBR x 4
// lanes (the D-PHY cannot reach HBR, so 1080p is recovered with lane count;
// a 4-lane sink path is required - pin assignment C/E and a 4-lane or
// native-DP sink). The link content is an eight-bar colorbar + a test tone;
// replace rgb / audio_sample_word with your own video and audio source.
//
// Build defines: DP_VENDOR_DPHY, GOWIN_PLL_IP   (see gowin_defines*.v)
///////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module top_tang_primer_25k (
    input  logic clk50_in,          // SOM 50 MHz oscillator

    // DP AUX channel: a true-LVDS pair with the board's bias/termination
    // network (1 Mbps Manchester, bidirectional). See src/dp_aux_pad.sv.
    inout  wire  dp_aux_p,
    inout  wire  dp_aux_n,
    input  logic dp_hpd,            // HPD level (from the sink, or, in USB-C
                                    // Alt Mode, reconstructed from PD by an MCU)

    output logic led,               // active high: link established

    // MIPI D-PHY M0 quad (dedicated hard-PHY pads; placed by the IP, not the
    // CST). DP main link leaves here; route through AC caps + SN75DP130.
    inout  wire  dphy_ck_p,
    inout  wire  dphy_ck_n,
    inout  wire  [3:0] dphy_d_p,
    inout  wire  [3:0] dphy_d_n
);

    // ------------------------------------------------------------------
    // Configuration: 720p60 RBR x2 (default) or 1080p60 RBR x4
    // ------------------------------------------------------------------
`ifdef DP_TP25K_1080P
    localparam bit HD    = 1'b1;
    localparam int LANES = 4;
`else
    localparam bit HD    = 1'b0;
    localparam int LANES = 2;
`endif
    localparam int H_VIS = HD ? 1920 : 1280;
    localparam int H_TOT = HD ? 2200 : 1650;
    localparam int H_SYN = HD ? 44   : 40;
    localparam int H_STA = HD ? 192  : 260;
    localparam int V_VIS = HD ? 1080 : 720;
    localparam int V_TOT = HD ? 1125 : 750;
    localparam int V_SYN = 5;
    localparam int V_STA = HD ? 41   : 25;
    // Pixel clock = 81 MHz (symbol clock) * 11 / PIX_DIV, via gowin_pixel_pll
    // VCO 891 MHz: 148.5 MHz (1080p, /6) or 74.25 MHz (720p, /12).
    localparam int PIX_DIV = HD ? 6 : 12;
    localparam int PIX_HZ  = HD ? 148_500_000 : 74_250_000;
    localparam int BAR_W   = H_VIS / 8;

    // ------------------------------------------------------------------
    // Clocks and reset
    //   clk100 : AUX/management clock          (gowin_mgmt_pll, shared PLL)
    //   clk54  : D-PHY TX PLL reference        (Gowin_PLL, generated IP)
    // The link-symbol clock (81 MHz) and the 101.25 MHz D-PHY byte clock are
    // PLL outputs owned by transceiver_bank_dphy; nothing to source here.
    // ------------------------------------------------------------------
    logic clk100, clk54, sys_pll_lock;
    gowin_mgmt_pll i_mgmt_pll (.lock(), .clkout(clk100), .clkin(clk50_in));

    Gowin_PLL i_sys_pll (
        .clkin   (clk50_in),
        .mdclk   (clk50_in),
        .clkout0 (),                 // 27 MHz  (unused)
        .clkout1 (),                 // 135 MHz (unused)
        .clkout2 (clk54),            // 54 MHz -> D-PHY PLL reference
        .lock    (sys_pll_lock)
    );

    // Power-on reset: hold until the system PLL locks, then ~21 ms more.
    logic [19:0] por_cnt = '0;
    logic        por_done = 1'b0;
    always_ff @(posedge clk50_in) begin
        if (!sys_pll_lock) begin
            por_cnt  <= '0;
            por_done <= 1'b0;
        end else if (por_cnt != 20'hFFFFF) begin
            por_cnt  <= por_cnt + 20'd1;
        end else begin
            por_done <= 1'b1;
        end
    end
    wire reset = !por_done;

    // ------------------------------------------------------------------
    // AUX channel analog front end (hardware-proven true-LVDS pad cell)
    // ------------------------------------------------------------------
    logic auxch_in, auxch_out, auxch_tri;
    dp_aux_pad #(.AUX_TLVDS(1)) i_aux_pad (
        .clk100    (clk100),
        .dp_aux_p  (dp_aux_p),
        .dp_aux_n  (dp_aux_n),
        .auxch_in  (auxch_in),
        .auxch_out (auxch_out),
        .auxch_tri (auxch_tri)
    );

    // ------------------------------------------------------------------
    // Test pattern: eight-bar colorbar + a 2-px white frame. Replace rgb
    // with your own video source (registered on clk_pixel, answering the
    // cx/cy coordinates dp_transmitter produces).
    // ------------------------------------------------------------------
    logic        clk_pixel;
    logic [11:0] cx;
    logic [10:0] cy;
    logic [23:0] rgb, bar;

    always_comb begin
        if      (cx < 12'(BAR_W*1)) bar = 24'hFFFFFF;  // white
        else if (cx < 12'(BAR_W*2)) bar = 24'hFFFF00;  // yellow
        else if (cx < 12'(BAR_W*3)) bar = 24'h00FFFF;  // cyan
        else if (cx < 12'(BAR_W*4)) bar = 24'h00FF00;  // green
        else if (cx < 12'(BAR_W*5)) bar = 24'hFF00FF;  // magenta
        else if (cx < 12'(BAR_W*6)) bar = 24'hFF0000;  // red
        else if (cx < 12'(BAR_W*7)) bar = 24'h0000FF;  // blue
        else                        bar = 24'h000000;  // black
    end

    always_ff @(posedge clk_pixel) begin
        if (cx < 12'd2 || cx >= 12'(H_VIS - 2) || cy < 11'd2 || cy >= 11'(V_VIS - 2))
            rgb <= 24'hFFFFFF;
        else
            rgb <= bar;
    end

    // ------------------------------------------------------------------
    // Audio: 48 kHz strobe + ~1 kHz sawtooth at -18 dB (replace with your
    // own source; drive clk_audio one clk_pixel wide at the sample rate).
    // ------------------------------------------------------------------
    logic               clk_audio;
    logic signed [28:0] aud_acc = -29'(PIX_HZ);
    logic [15:0]        tone;
    always_ff @(posedge clk_pixel) begin
        clk_audio <= 1'b0;
        if (!aud_acc[28]) begin
            aud_acc   <= aud_acc + 29'sd48_000 - 29'(PIX_HZ);
            clk_audio <= 1'b1;
            tone      <= tone + 16'd1365;
        end else
            aud_acc <= aud_acc + 29'sd48_000;
    end
    logic [15:0] audio_sample_word [1:0];
    assign audio_sample_word[0] = {{3{tone[15]}}, tone[15:3]};
    assign audio_sample_word[1] = {{3{tone[15]}}, tone[15:3]};

    // ------------------------------------------------------------------
    // DisplayPort transmitter (external D-PHY serializer). The pixel clock
    // is generated inside the core from the 81 MHz symbol clock
    // (DP synchronous clocking); the symbol stream is handed out over the
    // ext_* ports to transceiver_bank_dphy below.
    // ------------------------------------------------------------------
    logic        link_established, video_live;
    logic        clk_sym;
    logic [79:0] tx_symbols;
    logic [3:0]  powerup_channel, tx_running;

    dp_transmitter #(
        .LANE_COUNT       (LANES),
        .LINK_RATE_MBPS   (1620),             // RBR (the D-PHY cannot reach HBR)
        // Swing/pre-emphasis live in the external SN75DP130 regenerator
        // (it snoops the AUX training writes in auto mode), so the fabric AFE
        // sequencer is off and the sink's request is echoed into the lane-set
        // writes for the DP130 to apply.
        .ENABLE_AFE_ADJUST(0),
        .AFE_APPLY_ON_START(0),
        .ECHO_SINK_ADJUST (1),
        .HPD_DISCONNECT_RESETS(1),
        // Video timing: 720p60 (VIC 4) or 1080p60 (VIC 16); pixel clock is
        // 81 MHz * 11 / PIX_DIV via the core's gowin_pixel_pll (VCO 891).
        .H_VISIBLE (H_VIS), .H_TOTAL (H_TOT), .H_SYNC_WIDTH (H_SYN), .H_START (H_STA),
        .V_VISIBLE (V_VIS), .V_TOTAL (V_TOT), .V_SYNC_WIDTH (V_SYN), .V_START (V_STA),
        .PIXEL_CLK_MULT   (11),
        .PIXEL_CLK_DIV    (PIX_DIV),
        .PIXEL_PLL_IDIV   (1),
        .PIXEL_PLL_MDIV   (11),
        .PIXEL_PLL_ODIV0  (PIX_DIV),
        .PIXEL_PLL_FCLKIN ("81"),
        .AUDIO_RATE       (48000),
        .AUDIO_BIT_WIDTH  (16)
    ) i_dp (
        .clk100            (clk100),
        .refclk0           (1'b0),             // no on-chip SERDES on this part
        .refclk1           (1'b0),
        .sim_clk_pixel     (1'b0),
        .reset             (reset),
        .clk_audio         (clk_audio),
        .audio_sample_word (audio_sample_word),
        .clk_pixel         (clk_pixel),
        .rgb               (rgb),
        .cx                (cx),
        .cy                (cy),
        .frame_width(), .screen_width(), .frame_height(), .screen_height(),
        .dp_tx_lane_p      (),                 // on-chip SERDES lanes unused
        .dp_tx_lane_n      (),
        .hpd               (dp_hpd),
        .auxch_in          (auxch_in),
        .auxch_out         (auxch_out),
        .auxch_tri         (auxch_tri),
        .link_established  (link_established),
        .video_live        (video_live),
        // External-PHY interface (DP_VENDOR_DPHY): pre-8b/10b symbol stream
        // out, symbol clock in.
        .ext_symbol_clk    (clk_sym),
        .ext_tx_running    (tx_running),
        .ext_tx_symbols    (tx_symbols),
        .ext_powerup_channel(powerup_channel),
        .drp_dbg_idx       (5'd0)
        // All debug_* observe outputs are left unconnected in this example.
    );

    // ------------------------------------------------------------------
    // D-PHY serializer. REVERSE_LANES/LANE_MAP/POL_INV encode the carrier
    // board's lane routing and pair polarity; adjust them to match your PCB.
    // ------------------------------------------------------------------
    transceiver_bank_dphy #(
        .REVERSE_LANES (1),        // DP lane n -> D-PHY lane 3-n
        .LANE_MAP      (8'h00),    // non-zero overrides REVERSE_LANES
        .POL_INV       (4'h0),     // per-D-PHY-lane P/N invert
        .PROBE         (0)         // 1 = raw square wave on all lanes (scope)
    ) i_phy (
        .mgmt_clk        (clk100),
        .clk_dphy_ref    (clk54),
        .clk_md          (clk50_in),
        .reset           (reset),
        .powerup_channel (powerup_channel),
        .tx_running      (tx_running),
        .tx_symbol_clk   (clk_sym),
        .tx_symbols      (tx_symbols),
        .status          (),
        .tx_clk_out      (),
        .dphy_ck_p       (dphy_ck_p),
        .dphy_ck_n       (dphy_ck_n),
        .dphy_d_p        (dphy_d_p),
        .dphy_d_n        (dphy_d_n)
    );

    assign led = link_established;

endmodule
