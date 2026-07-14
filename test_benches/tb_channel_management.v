///////////////////////////////////////////////////////////////////////////////
// ./test_benches/tb_channel_management.v : 
//
// Author: Mike Field <hamster@snap.net.nz>
//
// Part of the DisplayPort_Verlog project - an open implementation of the 
// DisplayPort protocol for FPGA boards. 
//
// See https://github.com/hamsternz/DisplayPort_Verilog for latest versions.
//
///////////////////////////////////////////////////////////////////////////////
// Version |  Notes
// ----------------------------------------------------------------------------
//   1.0   | Initial Release
//
///////////////////////////////////////////////////////////////////////////////
//
// MIT License
// 
// Copyright (c) 2019 Mike Field
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
///////////////////////////////////////////////////////////////////////////////
//
// Want to say thanks?
//
// This design has taken many hours - 3 months of work for the initial VHDL
// design, and another month or so to convert it to Verilog for this release.
//
// I'm more than happy to share it if you can make use of it. It is released
// under the MIT license, so you are not under any onus to say thanks, but....
//
// If you what to say thanks for this design either drop me an email, or how about
// trying PayPal to my email (hamster@snap.net.nz)?
//
//  Educational use - Enough for a beer
//  Hobbyist use    - Enough for a pizza
//  Research use    - Enough to take the family out to dinner
//  Commercial use  - A weeks pay for an engineer (I wish!)
//
///////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps
module tb_channel_management;

    reg        clk100;
    wire [7:0] debug;

    wire       hpd;
    wire       auxch_in;
    wire       auxch_out;
    wire       auxch_tri;

        // Datapath requirements
    reg  [2:0] stream_channel_count;
    reg  [2:0] source_channel_count;

        // Datapath control
    wire       tx_clock_train;
    wire       tx_align_train;

        // Transceiver management
    wire [3:0] tx_powerup_channel;

    wire       tx_preemp_0p0;
    wire       tx_preemp_3p5;
    wire       tx_preemp_6p0;
           
    wire       tx_swing_0p4;
    wire       tx_swing_0p6;
    wire       tx_swing_0p8;
          
    reg  [3:0] tx_running;
    wire       tx_link_established;

    reg  [31:0] i, j;
    
initial begin
    clk100               = 1'b0;
        // Datapath requirements
    stream_channel_count = 3'b001;
    source_channel_count = 3'b001;
    tx_running           = 4'b0000;
end

`ifndef LINK_RATE_MBPS_TB
 `define LINK_RATE_MBPS_TB 1620
`endif

// transceivers report running as soon as they are powered (stub behaviour)
always @(posedge clk100)
    tx_running <= tx_powerup_channel;

// ----------------------------------------------------------------------
// Self-checks: (a) the DPCD 0x100 link-bandwidth byte in the message ROM
// matches the parameterised rate; (b) the full AUX exchange against the
// scripted dummy sink brings the link up.
// ----------------------------------------------------------------------
reg        rom_de = 0;
reg  [7:0] rom_msg = 8'h07;      // "set link bandwidth" message
wire [7:0] rom_data_rbr, rom_data_hbr;
wire       rom_we_rbr, rom_we_hbr;
dp_aux_messages #(.LINK_RATE_MBPS(1620)) i_rom_rbr
    (.clk(clk100), .msg_de(rom_de), .msg(rom_msg), .busy(),
     .aux_tx_wr_en(rom_we_rbr), .aux_tx_data(rom_data_rbr));
dp_aux_messages #(.LINK_RATE_MBPS(2700)) i_rom_hbr
    (.clk(clk100), .msg_de(rom_de), .msg(rom_msg), .busy(),
     .aux_tx_wr_en(rom_we_hbr), .aux_tx_data(rom_data_hbr));

integer errors = 0;
integer nbytes = 0;
reg [7:0] last_rbr, last_hbr;

always @(posedge clk100) begin
    if (rom_we_rbr) begin
        last_rbr <= rom_data_rbr;
        last_hbr <= rom_data_hbr;
        nbytes   <= nbytes + 1;
    end
end

initial begin
    #200;
    @(posedge clk100);
    rom_de <= 1'b1;
    @(posedge clk100);
    rom_de <= 1'b0;
    // message 7 emits 5 bytes; the last is the DPCD 0x100 value
    wait (nbytes == 5);
    @(posedge clk100);
    if (last_rbr !== 8'h06) begin
        $display("FAIL: RBR link-bw byte %02x (want 06)", last_rbr);
        errors = errors + 1;
    end
    if (last_hbr !== 8'h0A) begin
        $display("FAIL: HBR link-bw byte %02x (want 0A)", last_hbr);
        errors = errors + 1;
    end
    $display("ROM check done (RBR %02x, HBR %02x)", last_rbr, last_hbr);

    // full link negotiation against the scripted sink
    wait (tx_link_established === 1'b1);
    $display("link established at t=%0t", $time);
    if (errors == 0) $display("LINK TRAINING PASSED");
    else             $display("%0d ERRORS", errors);
    $finish;
end

initial begin
    #60_000_000;   // 60 ms watchdog
    $display("FAIL: link never established (timeout)");
    $finish;
end


always begin
    #5  clk100 = ~clk100; // generate a clock
end

wire dp_tx_hp_detect;
tb_dummy_sink i_tb_dummy_sink(
    .clk100           (clk100),
    .auxch_data       (auxch_in),
    .hotplug_detect   (hpd)
);


channel_management #(.LINK_RATE_MBPS(`LINK_RATE_MBPS_TB)) i_channel_management(
        .clk100               (clk100),
        .debug                (debug),

        .hpd                  (hpd),
        .auxch_in             (auxch_in),
        .auxch_out            (auxch_out),
        .auxch_tri            (auxch_tri),

        // Datapath requirements
        .stream_channel_count (stream_channel_count),
        .source_channel_count (source_channel_count),

        // Datapath control
        .tx_clock_train       (tx_clock_train),
        .tx_align_train       (tx_align_train),

        // Transceiver management
        .tx_powerup_channel   (tx_powerup_channel),

        .tx_preemp_0p0        (tx_preemp_0p0),
        .tx_preemp_3p5        (tx_preemp_3p5),
        .tx_preemp_6p0        (tx_preemp_6p0),
           
        .tx_swing_0p4         (tx_swing_0p4),
        .tx_swing_0p6         (tx_swing_0p6),
        .tx_swing_0p8         (tx_swing_0p8),
 
        .tx_running           (tx_running),
        .tx_link_established  (tx_link_established)
);

endmodule
