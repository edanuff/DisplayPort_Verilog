///////////////////////////////////////////////////////////////////////////////
// ./test_benches/reactive_dummy_sink.v : protocol-reactive DisplayPort sink
//
// Part of the DisplayPort_Verilog project - an open implementation of the
// DisplayPort protocol for FPGA boards.
//
// Replacement for the time-scripted tb_dummy_sink in FSM-level testbenches.
// tb_dummy_sink replays a reply script on a fixed timeline and (per its own
// header) must be revised whenever the AUX channel-management FSM changes.
// This sink instead DECODES each AUX request off the wire (Manchester) and
// answers it: native DPCD reads are served from a small register model,
// native writes are ACKed (training-pattern writes arm CR/EQ status), and
// I2C-over-AUX EDID transactions are ACKed with dummy data. It therefore
// tracks any transaction ordering the source FSM chooses.
//
// Adapted from the reactive hub model in tb_train_recover.v (backported from
// the a2fpga DP campaign), with the fault injection stripped: this sink
// always answers promptly and cleanly.
//
//   - CR is granted (0x202 = 0x11) as soon as TPS1 is written to 0x102.
//   - EQ/align is granted (0x202 = 0x77, 0x204 = 0x01) on TPS2/TPS3.
//   - Training cleared (0x102 = 0) leaves the lane status granted, so
//     post-training link checks stay green.
//
///////////////////////////////////////////////////////////////////////////////
// MIT License
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
///////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module reactive_dummy_sink(
    input  wire auxch_req,        // source's auxch_out
    input  wire auxch_tri,        // source's tristate (0 = source driving)
    output reg  auxch_data,       // reply stream -> source's auxch_in
    output reg  hotplug_detect
);

    localparam HB = 500;          // AUX half-bit, ns (1 Mbps Manchester)

    initial begin
        auxch_data     = 1'b0;
        hotplug_detect = 1'b0;
        #1000 hotplug_detect = 1'b1;
    end

    // ------------------------------------------------------------------
    // Sink-side DPCD model
    // ------------------------------------------------------------------
    reg [7:0] r202 = 8'h00;       // LANE0_1_STATUS
    reg [7:0] r204 = 8'h00;       // LANE_ALIGN_STATUS_UPDATED

    function [7:0] dpcd_read(input [19:0] a);
        case (a)
            20'h00000: dpcd_read = 8'h11;   // DPCD 1.1
            20'h00001: dpcd_read = 8'h0A;   // 2.7 Gbps max
            20'h00002: dpcd_read = 8'h82;   // 2 lanes, enhanced framing
            20'h00200: dpcd_read = 8'h01;   // one sink present
            20'h00202: dpcd_read = r202;
            20'h00204: dpcd_read = r204;
            20'h00205: dpcd_read = 8'h01;   // SINK_STATUS: receive port 0 in sync
            default:   dpcd_read = 8'h00;
        endcase
    endfunction

    // ------------------------------------------------------------------
    // Manchester AUX capture + decode (from the tb_train_recover model)
    // ------------------------------------------------------------------
    reg  [0:4095] hv;
    integer nh;
    reg  [7:0] req  [0:31];
    integer    req_len;
    reg  [7:0] rbuf [0:31];
    integer    rlen;
    integer i, j, k, b, bo, bitv;
    reg [7:0] byte_acc;
    reg  [19:0] req_addr;
    integer     dlen;
    integer     edid_reads = 0;

    task send_half(input v); begin auxch_data = v; #(HB); end endtask
    task send_bit_s(input v); begin send_half(v); send_half(~v); end endtask
    task send_raw8_s(input [7:0] h);
        begin for (b = 7; b >= 0; b = b - 1) send_half(h[b]); end
    endtask
    task send_byte_s(input [7:0] v);
        begin for (b = 7; b >= 0; b = b - 1) send_bit_s(v[b]); end
    endtask
    task send_reply;
        begin
            #8000;
            for (bo = 0; bo < 16; bo = bo + 1) send_bit_s(1'b0);
            send_raw8_s(8'b1111_0000);
            for (bo = 0; bo < rlen; bo = bo + 1) send_byte_s(rbuf[bo]);
            send_raw8_s(8'b1111_0000);
            auxch_data = 1'b0;
        end
    endtask

    initial forever begin
        @(negedge auxch_tri);
        nh = 0;
        #(HB/2);
        while (auxch_tri === 1'b0 && nh < 4096) begin
            hv[nh] = auxch_req;
            nh = nh + 1;
            #(HB);
        end
        decode_and_respond;
    end

    task decode_and_respond;
        begin
            // find the SYNC->start transition (1111_0000)
            i = 0;
            while (i < nh-8 &&
                   !( hv[i]   &  hv[i+1] &  hv[i+2] &  hv[i+3] &
                     ~hv[i+4] & ~hv[i+5] & ~hv[i+6] & ~hv[i+7]))
                i = i + 1;
            i = i + 8;
            req_len = 0; byte_acc = 8'h00; k = 0;
            while (i < nh-1) begin
                if (i < nh-3 && hv[i] & hv[i+1] & hv[i+2] & hv[i+3])
                    i = nh;                        // STOP pattern
                else begin
                    bitv = hv[i];
                    byte_acc = {byte_acc[6:0], bitv[0]};
                    k = k + 1;
                    if (k == 8) begin
                        req[req_len] = byte_acc;
                        req_len = req_len + 1;
                        k = 0;
                    end
                    i = i + 2;
                end
            end
            if (req_len >= 3) begin
                req_addr = {req[0][3:0], req[1], req[2]};
                dlen     = (req_len >= 4) ? req[3] + 1 : 0;
                case (req[0][7:4])
                4'h9: begin                        // native read
                    rbuf[0] = 8'h00;               // ACK
                    for (j = 0; j < dlen; j = j + 1)
                        rbuf[j+1] = dpcd_read(req_addr + j);
                    rlen = dlen + 1;
                    send_reply;
                end
                4'h8: begin                        // native write
                    if (req_addr == 20'h00102 && req_len >= 5) begin
                        if (req[4][3:0] == 4'h1) begin
                            r202 = 8'h11;          // TPS1 -> CR done
                            r204 = 8'h00;
                        end
                        if (req[4][3:0] == 4'h2 || req[4][3:0] == 4'h3) begin
                            r202 = 8'h77;          // TPS2/3 -> EQ + sym lock
                            r204 = 8'h01;          // interlane align done
                        end
                    end
                    rbuf[0] = 8'h00;               // ACK
                    rlen = 1;
                    send_reply;
                end
                4'h4: begin                        // I2C write (MOT): addr phase
                    rbuf[0] = 8'h00;
                    rlen = 1;
                    send_reply;
                end
                4'h5: begin                        // I2C read (MOT): EDID data
                    edid_reads = edid_reads + 1;
                    rbuf[0] = 8'h00;
                    for (j = 0; j < dlen; j = j + 1)
                        rbuf[j+1] = edid_reads*16 + j;
                    rlen = dlen + 1;
                    send_reply;
                end
                default: begin
                    rbuf[0] = 8'h00;
                    rlen = 1;
                    send_reply;
                end
                endcase
            end
        end
    endtask

endmodule
