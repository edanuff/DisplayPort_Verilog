///////////////////////////////////////////////////////////////////////////////
// synth_check_top.sv : Timing-viability build top (no SERDES/PLL IP yet)
//
// Part of the DisplayPort_Verilog project.
//
// Purpose: place-and-route the full dp_transmitter fabric logic on the
// real GW5AT device with the production clock frequencies, before any
// board is designed. The three clocks arrive on input pins (constrained
// in tang_mega_dp.sdc):
//   clk100_in  100 MHz  management/AUX
//   clk_sym_in 135 MHz  link symbol clock (stands in for tx_pcs_clkout)
//   clk_pix_in 148.5 MHz pixel clock (stands in for the pixel PLL)
// The SERDES stub inside transceiver_bank_gowin uses refclk0 directly as
// the symbol clock, so the entire datapath is timed at the real rates.
// Outputs are dummy pins so nothing is optimised away.
///////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module synth_check_top (
    input  logic clk50_in,       // board oscillator (GOWIN_PLL_IP builds)
    input  logic clk100_in,
    input  logic clk_sym_in,
    input  logic clk_pix_in,
    input  logic rst_n,
    input  logic hpd,
    input  logic auxch_in,
    output logic auxch_out,
    output logic auxch_tri,
    output logic [1:0] dp_tx_lane_p,
    output logic [1:0] dp_tx_lane_n,
    output logic link_established,
    output logic video_live,
    output logic dbg_xor
);

`ifdef GOWIN_PLL_IP
    logic clk100;
    gowin_mgmt_pll i_mgmt_pll (.lock(), .clkout(clk100), .clkin(clk50_in));
`else
    logic clk100;
    assign clk100 = clk100_in;
`endif

    logic clk_pixel;
    logic [11:0] cx;
    logic [10:0] cy;
    logic [23:0] rgb;
    always_ff @(posedge clk_pixel)
        rgb <= {cx[7:0], cy[7:0], cx[7:0] ^ cy[7:0]};

    // 48 kHz strobe + test tone in the pixel domain
    // phase accumulator kept in [-WRAP, 0): the strobe decision is a
    // sign-bit test, not a 28-bit magnitude compare
    logic        clk_audio;
    logic signed [28:0] aud_acc = -29'sd148_500_000;
    logic [15:0] tone;
    always_ff @(posedge clk_pixel) begin
        clk_audio <= 1'b0;
        if (!aud_acc[28]) begin
            aud_acc   <= aud_acc + 29'sd48_000 - 29'sd148_500_000;
            clk_audio <= 1'b1;
            tone      <= tone + 16'd1365;
        end else
            aud_acc <= aud_acc + 29'sd48_000;
    end
    logic [15:0] audio_sample_word [1:0];
    assign audio_sample_word[0] = tone;
    assign audio_sample_word[1] = tone;

    logic [7:0] debug;

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
        .refclk0           (clk_sym_in),
        .refclk1           (1'b0),
        .sim_clk_pixel     (clk_pix_in),
        .reset             (~rst_n),
        .clk_audio         (clk_audio),
        .audio_sample_word (audio_sample_word),
        .clk_pixel         (clk_pixel),
        .rgb               (rgb),
        .cx                (cx),
        .cy                (cy),
        .frame_width(), .screen_width(), .frame_height(), .screen_height(),
        .dp_tx_lane_p      (dp_tx_lane_p),
        .dp_tx_lane_n      (dp_tx_lane_n),
        .hpd               (hpd),
        .auxch_in          (auxch_in),
        .auxch_out         (auxch_out),
        .auxch_tri         (auxch_tri),
        .link_established  (link_established),
        .video_live        (video_live),
        .debug             (debug)
    );

    assign dbg_xor = ^debug;

endmodule
