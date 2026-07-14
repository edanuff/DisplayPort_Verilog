///////////////////////////////////////////////////////////////////////////////
// top_tang_mega.sv : Example board top for Tang Mega 138K Pro / 60K (GW5AT)
//
// Part of the DisplayPort_Verilog project.
//
// Instantiates dp_transmitter (720p60 RGB @ RBR 2-lane, 48 kHz audio) for
// a Gowin GW5AT board. See README.md in this directory for the SERDES IP
// generation steps and board caveats (the stock Tang Mega docks expose
// the transceiver lanes on PCIe/SFP+ connectors, not a DP receptacle -
// a breakout or custom carrier is required for a physical DP sink).
//
// Build defines: DP_VENDOR_GOWIN, GOWIN_SERDES_IP, GOWIN_PLL_IP
///////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module top_tang_mega (
    input  logic clk50,             // board oscillator
    input  logic rst_btn_n,

    // SERDES reference clock (MS5351 programmed to 135 MHz; see README)
    input  logic serdes_refclk_p,
    input  logic serdes_refclk_n,

    // DP main link (transceiver lane pins, via PCIe/SFP+ breakout)
    output logic [1:0] dp_tx_lane_p,
    output logic [1:0] dp_tx_lane_n,

    // DP AUX channel: pseudo-differential on two GPIOs with the board's
    // bias/termination network (1 Mbps Manchester, bidirectional)
    inout  wire  dp_aux_p,
    inout  wire  dp_aux_n,
    input  logic dp_hpd,

    output logic [1:0] led
);

    // ------------------------------------------------------------------
    // 100 MHz management clock from the board oscillator (Gowin PLL IP)
    // ------------------------------------------------------------------
    logic clk100;
`ifdef GOWIN_PLL_IP
    gowin_mgmt_pll i_mgmt_pll (.clkin(clk50), .clkout(clk100));
`else
    assign clk100 = clk50;          // lint placeholder
`endif

    // ------------------------------------------------------------------
    // AUX channel analog interface: drive/tri-state the pseudo-diff pair
    // ------------------------------------------------------------------
    logic auxch_in, auxch_out, auxch_tri;
    assign dp_aux_p = auxch_tri ? 1'bz : auxch_out;
    assign dp_aux_n = auxch_tri ? 1'bz : ~auxch_out;
    assign auxch_in = dp_aux_p;

    // ------------------------------------------------------------------
    // Test pattern: colour gradient; replace rgb with your video source.
    // For retro-core content (e.g. Apple II 280/560x192), render into an
    // integer-scaled window (5x vertical = 960 lines) centred in the
    // 1920x1080 frame and output black elsewhere.
    // ------------------------------------------------------------------
    logic clk_pixel;
    logic [11:0] cx;
    logic [10:0] cy;
    logic [23:0] rgb;
    always_ff @(posedge clk_pixel)
        rgb <= {cx[7:0], cy[7:0], cx[7:0] ^ cy[7:0]};

    // ------------------------------------------------------------------
    // Audio: 48 kHz strobe + sine/test tone (replace with your source)
    // ------------------------------------------------------------------
    logic        clk_audio;
    logic [31:0] aud_acc;
    logic [15:0] tone;
    always_ff @(posedge clk_pixel) begin
        clk_audio <= 1'b0;
        if (aud_acc + 48000 >= 148_500_000) begin
            aud_acc   <= aud_acc + 48000 - 148_500_000;
            clk_audio <= 1'b1;
            tone      <= tone + 16'd1365;   // ~1 kHz sawtooth at 48 kHz
        end else
            aud_acc <= aud_acc + 48000;
    end
    logic [15:0] audio_sample_word [1:0];
    assign audio_sample_word[0] = tone;
    assign audio_sample_word[1] = tone;

    // ------------------------------------------------------------------
    // DisplayPort transmitter: 1080p60 RGB, HBR x2, 48 kHz stereo
    // (pixel clock 148.5 MHz = 135 MHz word clock * 11/10; generate the
    // SERDES IP at 2.7 Gbps and the pixel PLL at 11/10 accordingly)
    // ------------------------------------------------------------------
    logic link_established, video_live;

    dp_transmitter #(
        .LANE_COUNT     (2),
        .LINK_RATE_MBPS (2700),
        .H_VISIBLE (1920), .H_TOTAL (2200), .H_SYNC_WIDTH (44), .H_START (192),
        .V_VISIBLE (1080), .V_TOTAL (1125), .V_SYNC_WIDTH (5),  .V_START (41),
        .PIXEL_CLK_MULT (11),
        .PIXEL_CLK_DIV  (10),
        .AUDIO_RATE     (48000),
        .AUDIO_BIT_WIDTH(16)
    ) i_dp (
        .clk100            (clk100),
        .refclk0           (serdes_refclk_p),  // dedicated refclk input
        .refclk1           (1'b0),
        .sim_clk_pixel     (1'b0),
        .reset             (~rst_btn_n),
        .clk_audio         (clk_audio),
        .audio_sample_word (audio_sample_word),
        .clk_pixel         (clk_pixel),
        .rgb               (rgb),
        .cx                (cx),
        .cy                (cy),
        .frame_width(), .screen_width(), .frame_height(), .screen_height(),
        .dp_tx_lane_p      (dp_tx_lane_p),
        .dp_tx_lane_n      (dp_tx_lane_n),
        .hpd               (dp_hpd),
        .auxch_in          (auxch_in),
        .auxch_out         (auxch_out),
        .auxch_tri         (auxch_tri),
        .link_established  (link_established),
        .video_live        (video_live),
        .debug             ()
    );

    assign led = {video_live, link_established};

endmodule
