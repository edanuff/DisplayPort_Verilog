///////////////////////////////////////////////////////////////////////////////
// tb_gowin_lane.v : Fabric 8b/10b lane path verification incl. TPS2
//
// Part of the DisplayPort_Verilog project.
//
// Runs the real main-link datapath (test_source -> main_stream_processing)
// through clock training (TPS1), align training (TPS2, which uses the
// forced-negative-disparity bit) and live video, encoding lane 0/1 words
// with lane_encoder_8b10b and decoding them back with the independent
// Benz decoder. Checks:
//   - decoded symbols match the pre-encode stream exactly
//   - zero code errors everywhere
//   - zero disparity errors, given that a forced character legally
//     restarts the receiver's disparity tracking at RD-
///////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module tb_gowin_lane;

reg clk = 0;
always #4 clk = ~clk;

reg tx_clock_train = 0, tx_align_train = 0, tx_link_established = 0;

wire [72:0] msa_merged_data;
wire        ready;
wire  [2:0] stream_channel_count;
wire [79:0] tx_symbols;

test_source i_src (.clk(clk), .stream_channel_count(stream_channel_count),
                   .ready(ready), .data(msa_merged_data));
main_stream_processing i_msp (
    .symbol_clk(clk), .tx_link_established(tx_link_established),
    .source_ready(ready), .tx_clock_train(tx_clock_train),
    .tx_align_train(tx_align_train), .in_data(msa_merged_data),
    .tx_symbols(tx_symbols));

reg reset = 1;
wire [19:0] code0, code1;
lane_encoder_8b10b enc0 (.clk(clk), .reset(reset),
                         .tx_symbol(tx_symbols[19:0]),  .tx_code(code0));
lane_encoder_8b10b enc1 (.clk(clk), .reset(reset),
                         .tx_symbol(tx_symbols[39:20]), .tx_code(code1));

// reference symbols delayed to match encoder latency
reg [39:0] ref_q;
always @(posedge clk) ref_q <= tx_symbols[39:0];

// ----------------------------------------------------------------------
// per-lane decode-and-check
// ----------------------------------------------------------------------
integer errors = 0;
integer checked = 0;
integer forced_seen = 0;

reg dec_disp0 = 0, dec_disp1 = 0;

// combinational decoders, reused across the two symbols of a cycle
reg  [9:0] dc_in;
reg        dc_dispin;
wire [8:0] dc_out;
wire       dc_dispout, dc_coderr, dc_disperr;
decode i_dec (.datain(dc_in), .dispin(dc_dispin), .dataout(dc_out),
              .dispout(dc_dispout), .code_err(dc_coderr), .disp_err(dc_disperr));

task check_lane(input [19:0] code, input [19:0] refsym, input lane);
    integer s;
    reg [9:0]  c;
    reg [9:0]  r;
    reg        dsp;
    begin
        dsp = lane ? dec_disp1 : dec_disp0;
        for (s = 0; s < 2; s = s + 1) begin
            c = s ? code[19:10]   : code[9:0];
            r = s ? refsym[19:10] : refsym[9:0];
            if (r[9]) begin
                dsp = 1'b0;          // forced char: receiver re-seeds at RD-
                forced_seen = forced_seen + 1;
            end
            dc_in = c; dc_dispin = dsp;
            #1;
            if (dc_out !== r[8:0]) begin
                if (errors < 20)
                    $display("FAIL: lane%0d decode %03x want %03x (t=%0t)",
                             lane, dc_out, r[8:0], $time);
                errors = errors + 1;
            end
            if (dc_coderr) begin
                if (errors < 20) $display("FAIL: lane%0d code_err (t=%0t)", lane, $time);
                errors = errors + 1;
            end
            if (dc_disperr) begin
                if (errors < 20) $display("FAIL: lane%0d disp_err (t=%0t)", lane, $time);
                errors = errors + 1;
            end
            dsp = dc_dispout;
            checked = checked + 1;
        end
        if (lane) dec_disp1 = dsp;
        else      dec_disp0 = dsp;
    end
endtask

integer i;

initial begin
    repeat (5) @(posedge clk);
    reset <= 0;
    repeat (2) @(posedge clk);

    // TPS1
    tx_clock_train <= 1;
    for (i = 0; i < 2000; i = i + 1) begin
        @(posedge clk); #1;
        check_lane(code0, ref_q[19:0], 0);
        check_lane(code1, ref_q[39:20], 1);
    end
    // TPS2 (uses forced disparity)
    tx_clock_train <= 0; tx_align_train <= 1;
    for (i = 0; i < 2000; i = i + 1) begin
        @(posedge clk); #1;
        check_lane(code0, ref_q[19:0], 0);
        check_lane(code1, ref_q[39:20], 1);
    end
    if (forced_seen == 0) begin
        $display("FAIL: TPS2 produced no forced-disparity characters");
        errors = errors + 1;
    end
    // live stream (scrambled video incl. idle transition)
    tx_align_train <= 0; tx_link_established <= 1;
    for (i = 0; i < 100000; i = i + 1) begin
        @(posedge clk); #1;
        check_lane(code0, ref_q[19:0], 0);
        check_lane(code1, ref_q[39:20], 1);
    end

    $display("checked %0d symbols, %0d forced", checked, forced_seen);
    if (errors == 0) $display("ALL LANE ENCODE CHECKS PASSED");
    else             $display("%0d ERRORS", errors);
    $finish;
end

endmodule
