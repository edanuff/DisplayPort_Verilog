///////////////////////////////////////////////////////////////////////////////
// ./src/gowin/csr_replay_rom_lut.v : PLACEHOLDER CSR replay ROM
//
// Part of the DisplayPort_Verilog project - an open implementation of the
// DisplayPort protocol for FPGA boards.
//
// transceiver_bank_gowin.v contains a wedge-recovery "CSR replay" engine:
// when the link watchdog decides the SERDES quad is wedged, it replays the
// ENTIRE generator-emitted CSR write sequence (the register writes the Gowin
// SERDES IP generator performs at configuration time) through the DRP/upar
// port to cold-restart the PHY without a fabric reconfiguration.
//
// The replay DATA is inherently per-die and per-configuration: it must be
// the exact write sequence emitted by the IP generator for YOUR part and
// YOUR .ipc settings.  Boards therefore provide their own csr_replay_rom_lut
// module (same module name, one per project — a shared `include was tried
// and silently served the wrong die's CSR writes to a build, so a missing
// module now fails the build loudly).  Extract the {addr, data} pairs from
// the generator's .csr emission for your dp_serdes configuration and encode
// them as data = {addr[23:0], wrdata[31:0]}, len = number of entries.
//
// AS SHIPPED this is a STUB so the generic tree elaborates: len = 1 and the
// single entry writes 32'h0 to address 24'h0.  That satisfies the replay
// handshake (the engine would never complete against len = 0) but does NOT
// restore a wedged PHY.  Replace it with your real sequence before relying
// on the watchdog cold-restart path on hardware.
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

module csr_replay_rom_lut(
    input  wire [9:0]  idx,
    output wire [55:0] data,
    output wire [9:0]  len
);
    // STUB: one benign entry — see header. Replace with the generator-
    // emitted CSR write sequence for your die/configuration.
    assign data = 56'd0;      // {addr[23:0]=0, wrdata[31:0]=0}
    assign len  = 10'd1;
endmodule
