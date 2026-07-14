///////////////////////////////////////////////////////////////////////////////
// tb_dp_frame_audio.v : Full-chain frame test with audio SDPs
//
// Part of the DisplayPort_Verilog project.
//
// 720p60 RGB @ RBR 2-lane with 48 kHz stereo audio: timing generator ->
// CDC FIFO -> stream packer -> SDP engine -> MSA inserter. Audio samples
// are a deterministic ramp (L[n] = n*331, R[n] = n*7919, mod 2^16) strobed
// at ~48 kHz in the pixel domain. The pre-scrambler symbol stream is
// dumped for misc/check_dp_audio.c (SDP ECC + PCM reconstruction) and
// misc/check_dp_frame.c (video still pixel-exact).
///////////////////////////////////////////////////////////////////////////////
`timescale 1ps / 1ps

module tb_dp_frame_audio;

// Configuration - override with -D for other modes:
//   default 720p60 @ RBR 2-lane (pixel = symclk * 11/12)
//   1080p60 @ HBR 2-lane: MULT=11 DIV=10, 2200x1125, TSYM_2=5500 TPIX_2=5000
`ifndef CFG_HVIS
 `define CFG_HVIS 1280
 `define CFG_HTOT 1650
 `define CFG_VVIS 720
 `define CFG_VTOT 750
 `define CFG_MULT 11
 `define CFG_DIV  12
 `define CFG_TSYM_2 5500
 `define CFG_TPIX_2 6000
 `define CFG_MVAL 24'h3AAAB
 `define CFG_LINK 1620
 `define CFG_BITW 11
 `define CFG_FIFO_AB 11
 `define CFG_AUD_WRAP 83333333
 `define CFG_HSW 40
 `define CFG_VSW 5
 `define CFG_HSTART 260
 `define CFG_VSTART 25
`endif

localparam LANE_COUNT = 2;
localparam H_VISIBLE = `CFG_HVIS, H_TOTAL = `CFG_HTOT,
           V_VISIBLE = `CFG_VVIS, V_TOTAL = `CFG_VTOT;
localparam TU_SIZE = 64;
localparam SYMS_PER_LINE = H_TOTAL * 2 * `CFG_DIV / `CFG_MULT;
localparam VALID_NUM = TU_SIZE*3*`CFG_MULT;
localparam VALID_DEN = 2*`CFG_DIV*LANE_COUNT;
localparam PREFILL   = H_VISIBLE/LANE_COUNT;
localparam M_VALUE   = `CFG_MVAL;
localparam N_VALUE   = 24'h080000;
localparam BITW      = `CFG_BITW;
localparam FIFO_AB   = `CFG_FIFO_AB;

localparam DUMP_CYCLES = SYMS_PER_LINE/2 * V_TOTAL * 9 / 4;  // ~2.25 frames

reg clk_sym = 0, clk_pix = 0;
always #(`CFG_TSYM_2) clk_sym = ~clk_sym;
always #(`CFG_TPIX_2) clk_pix = ~clk_pix;

reg reset = 1, reset_px = 1;

// ----------------------------------------------------------------------
// Video: coordinate gradient
// ----------------------------------------------------------------------
wire [BITW-1:0] cx; wire [10:0] cy;
reg [23:0] rgb;
always @(posedge clk_pix) rgb <= {cx[7:0], cy[7:0], cx[7:0] ^ cy[7:0]};

// ----------------------------------------------------------------------
// Audio: 48 kHz strobe in pixel domain, deterministic ramp samples
// F_pix here is 83.333 MHz -> divider accumulator
// ----------------------------------------------------------------------
`ifndef CFG_AUDIO_RATE
 `define CFG_AUDIO_RATE 48000
`endif
localparam AUDIO_RATE = `CFG_AUDIO_RATE;

reg        clk_audio = 0;
reg [31:0] aud_acc = 0;
reg [15:0] aud_n = 0;
wire [15:0] sample_l = aud_n * 16'd331;
wire [15:0] sample_r = aud_n * 16'd7919;
localparam AUD_INC  = AUDIO_RATE;
localparam AUD_WRAP = `CFG_AUD_WRAP;   // pixel clock frequency in Hz
always @(posedge clk_pix) begin
    clk_audio <= 1'b0;
    if (!reset_px) begin
        if (aud_acc + AUD_INC >= AUD_WRAP) begin
            aud_acc   <= aud_acc + AUD_INC - AUD_WRAP;
            clk_audio <= 1'b1;
            aud_n     <= aud_n + 1'b1;   // sample for NEXT strobe
        end else begin
            aud_acc <= aud_acc + AUD_INC;
        end
    end
end

// ----------------------------------------------------------------------
// Front-end chain
// ----------------------------------------------------------------------
wire [47:0] fifo_wdata, fifo_rpix;
wire fifo_wsof, fifo_wen, fifo_rsof, fifo_rvalid, fifo_rd;
wire [FIFO_AB:0] fifo_rlevel;
wire capture_arm;
reg  capture_arm_m = 0, capture_arm_px = 0;
always @(posedge clk_pix) begin
    capture_arm_m  <= capture_arm;
    capture_arm_px <= capture_arm_m;
end

dp_video_timing #(
    .LANE_COUNT(2), .H_VISIBLE(H_VISIBLE), .H_TOTAL(H_TOTAL),
    .V_VISIBLE(V_VISIBLE), .V_TOTAL(V_TOTAL), .BIT_WIDTH(BITW), .BIT_HEIGHT(11)
) i_timing (
    .clk_pixel(clk_pix), .reset(reset_px), .capture_arm(capture_arm_px),
    .rgb(rgb), .cx(cx), .cy(cy),
    .fifo_wdata(fifo_wdata), .fifo_wsof(fifo_wsof), .fifo_wen(fifo_wen)
);

pixel_cdc_fifo #(.WIDTH(49), .ADDR_BITS(FIFO_AB)) i_fifo (
    .wclk(clk_pix), .wreset(reset_px), .wdata({fifo_wsof, fifo_wdata}),
    .wen(fifo_wen), .wfull(),
    .rclk(clk_sym), .rreset(reset), .rdata({fifo_rsof, fifo_rpix}),
    .rvalid(fifo_rvalid), .rd_en(fifo_rd), .rlevel(fifo_rlevel)
);

wire [72:0] packed_data;
wire ready, sdp_gap, frame_pulse, underrun;
wire [7:0]  maud_byte;
wire [23:0] maud;
wire audio_mute, strobe_sym, buffer_ready, buffer_take;
wire [127:0] audio_buffer;

video_stream_packer #(
    .LANE_COUNT(2), .H_VISIBLE(H_VISIBLE), .V_VISIBLE(V_VISIBLE),
    .V_TOTAL(V_TOTAL), .TU_SIZE(TU_SIZE), .SYMS_PER_LINE(SYMS_PER_LINE),
    .VALID_NUM(VALID_NUM), .VALID_DEN(VALID_DEN), .PREFILL(PREFILL)
) i_packer (
    .clk(clk_sym), .reset(reset),
    .mvid_byte(M_VALUE[7:0]), .maud_byte(maud_byte), .audio_mute(audio_mute),
    .fifo_rdata(fifo_rpix), .fifo_rsof(fifo_rsof), .fifo_rvalid(fifo_rvalid),
    .fifo_rd(fifo_rd), .fifo_rlevel(16'(fifo_rlevel)),
    .capture_arm(capture_arm), .ready(ready), .data(packed_data),
    .sdp_gap(sdp_gap), .frame_pulse(frame_pulse), .underrun(underrun)
);

audio_sample_buffer #(.AUDIO_BIT_WIDTH(16)) i_abuf (
    .clk_pixel(clk_pix), .clk_audio(clk_audio),
    .sample_l(sample_l), .sample_r(sample_r),
    .clk_sym(clk_sym), .reset(reset),
    .strobe_sym(strobe_sym), .buffer(audio_buffer),
    .buffer_count(), .buffer_ready(buffer_ready), .buffer_take(buffer_take)
);

maud_measure #(.AUDIO_RATE(AUDIO_RATE), .LINK_RATE_MBPS(`CFG_LINK)) i_maud (
    .clk_sym(clk_sym), .reset(reset), .strobe_sym(strobe_sym),
    .maud(maud), .maud_byte(maud_byte)
);

wire [72:0] sdp_merged;
sdp_engine #(.LANE_COUNT(2), .AUDIO_BIT_WIDTH(16), .AUDIO_RATE(AUDIO_RATE)) i_sdp (
    .clk(clk_sym), .reset(reset),
    .in_data(packed_data), .sdp_gap(sdp_gap), .frame_pulse(frame_pulse),
    .out_data(sdp_merged),
    .buffer(audio_buffer), .buffer_ready(buffer_ready), .buffer_take(buffer_take),
    .maud(maud), .audio_mute(audio_mute)
);

wire [72:0] msa_merged_data;
msa_inserter_2ch i_msa (
    .clk(clk_sym), .active(1'b1),
    .M_value(M_VALUE), .N_value(N_VALUE),
    .H_visible(H_VISIBLE[11:0]), .V_visible(V_VISIBLE[11:0]),
    .H_total(H_TOTAL[11:0]), .V_total(V_TOTAL[11:0]),
    .H_sync_width(12'(`CFG_HSW)), .V_sync_width(12'(`CFG_VSW)),
    .H_start(12'(`CFG_HSTART)), .V_start(12'(`CFG_VSTART)),
    .H_vsync_active_high(1'b1), .V_vsync_active_high(1'b1),
    .flag_sync_clock(1'b1), .flag_YCCnRGB(1'b0), .flag_422n444(1'b0),
    .flag_range_reduced(1'b0), .flag_interlaced_even(1'b0),
    .flag_YCC_colour_709(1'b0), .flags_3d_Indicators(2'b00),
    .bits_per_colour(5'b01000),
    .in_data(sdp_merged), .out_data(msa_merged_data)
);

// ----------------------------------------------------------------------
// Run and dump
// ----------------------------------------------------------------------
integer f, i, underrun_seen = 0;

initial begin
    f = $fopen(`DUMP_FILE, "w");
    repeat (10) @(posedge clk_sym);
    reset <= 0;
    repeat (10) @(posedge clk_pix);
    reset_px <= 0;

    i = 0;
    while (!ready && i < 3_000_000) begin
        @(posedge clk_sym); i = i + 1;
    end
    if (!ready) begin
        $display("FAIL: packer never became ready");
        $finish;
    end
    $display("packer ready after %0d cycles", i);

    for (i = 0; i < DUMP_CYCLES; i = i + 1) begin
        @(posedge clk_sym);
        $fdisplay(f, "%b %b %b %b",
                  msa_merged_data[8:0],  msa_merged_data[17:9],
                  msa_merged_data[26:18], msa_merged_data[35:27]);
        if (underrun && !underrun_seen) begin
            underrun_seen = 1;
            $display("FAIL: FIFO underrun at dump cycle %0d", i);
        end
    end

    $fclose(f);
    if (!underrun_seen)
        $display("PASS: no FIFO underrun over %0d cycles", DUMP_CYCLES);
    $display("final maud=%0d mute=%b", maud, audio_mute);
    $display("DUMP DONE");
    $finish;
end

endmodule
