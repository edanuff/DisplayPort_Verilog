///////////////////////////////////////////////////////////////////////////////
// tb_maud_measure.v : Maud measurement convergence test
//
// Part of the DisplayPort_Verilog project.
//
// Drives maud_measure with an audio strobe deliberately +200 ppm off
// nominal 48 kHz (against an 81 MHz symbol-domain clock) and checks that
// after one full measurement window the reported Maud lands on the
// ideal value 4972 +/- 1 (nominal 48 kHz -> 4971).
///////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module tb_maud_measure;

reg clk = 0;
always #5 clk = ~clk;

reg reset = 1;
reg strobe = 0;

// strobe rate / clk rate = 48009.6 / 81e6  (+200 ppm)
reg [63:0] acc = 0;
localparam [63:0] INC  = 64'd480096;      // 48009.6 * 10
localparam [63:0] WRAP = 64'd810000000;   // 81e6 * 10

always @(posedge clk) begin
    strobe <= 1'b0;
    if (!reset) begin
        if (acc + INC >= WRAP) begin
            acc    <= acc + INC - WRAP;
            strobe <= 1'b1;
        end else begin
            acc <= acc + INC;
        end
    end
end

wire [23:0] maud;
wire [7:0]  maud_byte;

maud_measure #(.AUDIO_RATE(48000), .LINK_RATE_MBPS(1620)) dut (
    .clk_sym(clk), .reset(reset), .strobe_sym(strobe),
    .maud(maud), .maud_byte(maud_byte)
);

integer i, errors = 0;

initial begin
    repeat (5) @(posedge clk);
    reset <= 0;
    @(posedge clk);

    if (maud !== 24'd4971) begin
        $display("FAIL: nominal seed %0d (want 4971)", maud);
        errors = errors + 1;
    end

    // one full window = 2^23 cycles, plus margin
    for (i = 0; i < 9_000_000; i = i + 1) @(posedge clk);

    // ideal for +200ppm: 48009.6 * 2^24/162e6 = 4972.2
    if (maud < 24'd4971 || maud > 24'd4973) begin
        $display("FAIL: measured maud %0d (want 4972 +/-1)", maud);
        errors = errors + 1;
    end else begin
        $display("measured maud = %0d after one window", maud);
    end
    if (maud_byte !== maud[7:0]) begin
        $display("FAIL: maud_byte mismatch"); errors = errors + 1;
    end

    if (errors == 0) $display("MAUD CONVERGENCE PASSED");
    else             $display("%0d ERRORS", errors);
    $finish;
end

endmodule
