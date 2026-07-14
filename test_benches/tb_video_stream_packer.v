///////////////////////////////////////////////////////////////////////////////
// tb_video_stream_packer.v : Full-frame test of the generic video front-end
//
// Part of the DisplayPort_Verilog project.
//
// Drives dp_video_timing -> pixel_cdc_fifo -> video_stream_packer ->
// msa_inserter_2ch with a coordinate gradient (r=cx, g=cy, b=cx^cy) at
// exact 11:12 pixel:symbol clock ratio (720p60 @ RBR 2-lane), and dumps
// the pre-scrambler symbol stream for misc/check_dp_frame.c to verify
// pixel-exactly.
//
// Pass/fail of the in-sim checks is printed at the end; the dump file is
// checked by the external tool.
///////////////////////////////////////////////////////////////////////////////
`timescale 1ps / 1ps

module tb_video_stream_packer;

// Configuration - override with -D for other modes (see 800x600 1-lane run):
//   default: 720p60 RGB @ RBR 2-lane, pixel clock = symclk * 11/12
`ifndef CFG_LANES
 `define CFG_LANES 2
 `define CFG_HVIS 1280
 `define CFG_HTOT 1650
 `define CFG_VVIS 720
 `define CFG_VTOT 750
 `define CFG_TU   64
 `define CFG_MULT 11
 `define CFG_DIV  12
 `define CFG_TSYM_2 5500     // half-period of symbol clock (ps)
 `define CFG_TPIX_2 6000     // half-period of pixel clock (ps)
 `define CFG_MVAL 24'h3AAAB  // round(MULT/(2*DIV) * 2^19)
`endif
`ifndef CFG_HSW
 `define CFG_HSW 40
 `define CFG_VSW 5
 `define CFG_HSTART 260
 `define CFG_VSTART 25
`endif

localparam LANE_COUNT = `CFG_LANES;
localparam H_VISIBLE = `CFG_HVIS, H_TOTAL = `CFG_HTOT,
           V_VISIBLE = `CFG_VVIS, V_TOTAL = `CFG_VTOT;
localparam TU_SIZE = `CFG_TU;
localparam SYMS_PER_LINE = H_TOTAL * 2 * `CFG_DIV / `CFG_MULT;
localparam VALID_NUM = TU_SIZE*3*`CFG_MULT;
localparam VALID_DEN = 2*`CFG_DIV*LANE_COUNT;
localparam PREFILL   = H_VISIBLE/LANE_COUNT;
localparam M_VALUE   = `CFG_MVAL;
localparam N_VALUE   = 24'h080000;

localparam DUMP_CYCLES = SYMS_PER_LINE/2 * V_TOTAL * 9 / 4;  // ~2.25 frames

reg clk_sym = 0, clk_pix = 0;
always #(`CFG_TSYM_2) clk_sym = ~clk_sym;
always #(`CFG_TPIX_2) clk_pix = ~clk_pix;

reg reset = 1;
reg reset_px = 1;   // released after capture_arm has propagated, so the
                    // timing generator starts capture at its first (0,0)

// ----------------------------------------------------------------------
// Pixel source: gradient keyed to coordinates
// ----------------------------------------------------------------------
wire [10:0] cx;
wire  [9:0] cy;
reg  [23:0] rgb;
always @(posedge clk_pix)
    rgb <= {cx[7:0], cy[7:0], cx[7:0] ^ cy[7:0]};

// ----------------------------------------------------------------------
// Front-end chain
// ----------------------------------------------------------------------
wire [24*LANE_COUNT-1:0] fifo_wdata, fifo_rpix;
wire fifo_wsof, fifo_wen, fifo_rsof, fifo_rvalid, fifo_rd;
wire [11:0] fifo_rlevel;
wire capture_arm;
reg  capture_arm_m = 0, capture_arm_px = 0;
always @(posedge clk_pix) begin
    capture_arm_m  <= capture_arm;
    capture_arm_px <= capture_arm_m;
end

dp_video_timing #(
    .LANE_COUNT(LANE_COUNT), .H_VISIBLE(H_VISIBLE), .H_TOTAL(H_TOTAL),
    .V_VISIBLE(V_VISIBLE), .V_TOTAL(V_TOTAL), .BIT_WIDTH(11), .BIT_HEIGHT(10)
) i_timing (
    .clk_pixel(clk_pix), .reset(reset_px), .capture_arm(capture_arm_px),
    .rgb(rgb), .cx(cx), .cy(cy),
    .fifo_wdata(fifo_wdata), .fifo_wsof(fifo_wsof), .fifo_wen(fifo_wen)
);

pixel_cdc_fifo #(.WIDTH(24*LANE_COUNT+1), .ADDR_BITS(11)) i_fifo (
    .wclk(clk_pix), .wreset(reset), .wdata({fifo_wsof, fifo_wdata}),
    .wen(fifo_wen), .wfull(),
    .rclk(clk_sym), .rreset(reset), .rdata({fifo_rsof, fifo_rpix}),
    .rvalid(fifo_rvalid), .rd_en(fifo_rd), .rlevel(fifo_rlevel)
);

wire [72:0] packed_data;
wire ready, sdp_gap, underrun;

video_stream_packer #(
    .LANE_COUNT(LANE_COUNT), .H_VISIBLE(H_VISIBLE), .V_VISIBLE(V_VISIBLE),
    .V_TOTAL(V_TOTAL), .TU_SIZE(TU_SIZE), .SYMS_PER_LINE(SYMS_PER_LINE),
    .VALID_NUM(VALID_NUM), .VALID_DEN(VALID_DEN), .PREFILL(PREFILL)
) i_packer (
    .clk(clk_sym), .reset(reset),
    .mvid_byte(M_VALUE[7:0]), .maud_byte(8'h00), .audio_mute(1'b0),
    .fifo_rdata(fifo_rpix), .fifo_rsof(fifo_rsof), .fifo_rvalid(fifo_rvalid),
    .fifo_rd(fifo_rd), .fifo_rlevel({4'b0, fifo_rlevel}),
    .capture_arm(capture_arm), .ready(ready), .data(packed_data),
    .sdp_gap(sdp_gap), .underrun(underrun)
);

wire [72:0] msa_merged_data;
generate
if (LANE_COUNT == 1) begin : g_msa1
    msa_inserter_1ch i_msa (
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
        .in_data(packed_data), .out_data(msa_merged_data)
    );
end else begin : g_msa2
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
        .in_data(packed_data), .out_data(msa_merged_data)
    );
end
endgenerate

// ----------------------------------------------------------------------
// Run control and dump
// ----------------------------------------------------------------------
integer f;
integer i;
integer underrun_seen = 0;

initial begin
    f = $fopen(`DUMP_FILE, "w");
    repeat (10) @(posedge clk_sym);
    reset = 0;
    repeat (10) @(posedge clk_pix);
    reset_px = 0;

    // wait for the packer to start (prefill + frame alignment)
    i = 0;
    while (!ready && i < 3_000_000) begin
        @(posedge clk_sym);
        i = i + 1;
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
            $display("FAIL: FIFO underrun at dump cycle %0d (rlevel=%0d)", i, fifo_rlevel);
        end
    end

    $fclose(f);
    if (!underrun_seen)
        $display("PASS: no FIFO underrun over %0d cycles", DUMP_CYCLES);
    $display("DUMP DONE");
    $finish;
end

endmodule
