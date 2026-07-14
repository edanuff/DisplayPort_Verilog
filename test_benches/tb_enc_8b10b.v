///////////////////////////////////////////////////////////////////////////////
// tb_enc_8b10b.v : Exhaustive 8b/10b encoder verification
//
// Part of the DisplayPort_Verilog project.
//
// Checks, for every D-code (256) and every valid K-code (12), at both
// input disparities:
//   - round trip through the independent Benz decoder (identity, no
//     code/disparity errors, matching K flag)
//   - code disparity arithmetic (ones count vs disp_out)
// Then checks known DP-critical encodings (K28.5+/-, D10.2 for TPS1) and
// the force_neg override, and finally serialises 20k random symbols to
// confirm run lengths never exceed 5 bits.
///////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module tb_enc_8b10b;

reg  [8:0] din;
reg        disp_in, force_neg;
wire [9:0] dout;
wire       disp_out;

enc_8b10b dut (.din(din), .disp_in(disp_in), .force_neg(force_neg),
               .dout(dout), .disp_out(disp_out));

// independent decoder (Benz): input bit order ji hgfiedcba as encoder output
wire [8:0] dec_data;
wire dec_dispout, code_err, disp_err;
decode i_dec (.datain(dout), .dispin(disp_in_dec), .dataout(dec_data),
              .dispout(dec_dispout), .code_err(code_err), .disp_err(disp_err));
reg disp_in_dec;

integer errors = 0;
integer d, k, i, ones;
reg [8:0] kcodes [0:11];

// run-length tracking
reg [9:0] code_q;
integer run, maxrun, bitv, lastbit;

task check_sym(input [8:0] sym);
    begin
        din = sym;
        force_neg = 0;
        for (d = 0; d < 2; d = d + 1) begin
            disp_in = d[0];
            disp_in_dec = d[0];
            #1;
            // round trip
            if (dec_data !== sym) begin
                if (errors < 20)
                    $display("FAIL: roundtrip %03x disp %0d -> %03x (code %b)",
                             sym, d, dec_data, dout);
                errors = errors + 1;
            end
            if (code_err) begin
                if (errors < 20) $display("FAIL: code_err %03x disp %0d", sym, d);
                errors = errors + 1;
            end
            if (disp_err) begin
                if (errors < 20) $display("FAIL: disp_err %03x disp %0d", sym, d);
                errors = errors + 1;
            end
            // disparity arithmetic
            ones = 0;
            for (i = 0; i < 10; i = i + 1) ones = ones + dout[i];
            if (ones == 5 && disp_out !== disp_in) begin
                if (errors < 20) $display("FAIL: balanced code moved disp %03x", sym);
                errors = errors + 1;
            end
            if (ones == 6 && disp_out !== 1'b1) begin
                if (errors < 20) $display("FAIL: +2 code disp %03x", sym);
                errors = errors + 1;
            end
            if (ones == 4 && disp_out !== 1'b0) begin
                if (errors < 20) $display("FAIL: -2 code disp %03x", sym);
                errors = errors + 1;
            end
            if (ones < 4 || ones > 6) begin
                if (errors < 20) $display("FAIL: illegal weight %0d for %03x", ones, sym);
                errors = errors + 1;
            end
        end
    end
endtask

initial begin
    kcodes[0]  = 9'h11C; // K28.0
    kcodes[1]  = 9'h13C; // K28.1
    kcodes[2]  = 9'h15C; // K28.2
    kcodes[3]  = 9'h17C; // K28.3
    kcodes[4]  = 9'h19C; // K28.4
    kcodes[5]  = 9'h1BC; // K28.5
    kcodes[6]  = 9'h1DC; // K28.6
    kcodes[7]  = 9'h1FC; // K28.7
    kcodes[8]  = 9'h1F7; // K23.7
    kcodes[9]  = 9'h1FB; // K27.7
    kcodes[10] = 9'h1FD; // K29.7
    kcodes[11] = 9'h1FE; // K30.7

    // all data codes
    for (k = 0; k < 256; k = k + 1)
        check_sym({1'b0, k[7:0]});
    // all control codes
    for (k = 0; k < 12; k = k + 1)
        check_sym(kcodes[k]);

    // known encodings (a-first: dout[0]=a): K28.5 RD- = 001111 1010,
    // K28.5 RD+ = 110000 0101, D10.2 RD any = 010101 0101 (balanced)
    din = 9'h1BC; disp_in = 0; force_neg = 0; #1;
    if (dout !== 10'b0101_111100) begin
        $display("FAIL: K28.5 RD- got %b", dout); errors = errors + 1;
    end
    disp_in = 1; #1;
    if (dout !== 10'b1010_000011) begin
        $display("FAIL: K28.5 RD+ got %b", dout); errors = errors + 1;
    end
    // force_neg overrides positive running disparity
    force_neg = 1; #1;
    if (dout !== 10'b0101_111100) begin
        $display("FAIL: K28.5 force_neg got %b", dout); errors = errors + 1;
    end
    force_neg = 0;
    din = 9'h04A; disp_in = 0; #1;   // D10.2: abcdei=010101 fghj=0101
    if (dout !== 10'b1010_101010) begin   // dout[0]=a
        $display("FAIL: D10.2 got %b", dout); errors = errors + 1;
    end

    // run-length across a random serial stream
    maxrun = 0; run = 0; lastbit = 2;
    disp_in = 0; force_neg = 0;
    for (k = 0; k < 20000; k = k + 1) begin
        if ($random % 10 == 0)
            din = kcodes[($random & 31) % 12];
        else
            din = {1'b0, $random & 8'hFF} & 9'h0FF;
        #1;
        code_q = dout;
        disp_in = disp_out;   // chain running disparity
        for (i = 0; i < 10; i = i + 1) begin
            bitv = code_q[i];
            if (bitv === lastbit) run = run + 1;
            else begin
                if (run > maxrun) maxrun = run;
                run = 1; lastbit = bitv;
            end
        end
    end
    if (maxrun > 5) begin
        $display("FAIL: run length %0d > 5", maxrun); errors = errors + 1;
    end else
        $display("max run length %0d over 20k symbols", maxrun);

    if (errors == 0) $display("ALL 8B10B CHECKS PASSED");
    else             $display("%0d ERRORS", errors);
    $finish;
end

endmodule
