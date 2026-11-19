///////////////////////////////////////////////////////////////////////////////
// dp_aux_pad — DisplayPort AUX-channel pad cell for Gowin Arora-V parts.
//
// Part of the DisplayPort_Verilog project. This is the hardware-proven AUX
// electrical front end (the closed-loop AUX policy in src/auxch/ was built
// and validated against it); it is kept as one reusable cell so every board
// top shares the same source of truth.
//
// AUX_TLVDS=1 (recommended, hardware-proven closed-loop config):
//   drive the two AUX pins as a true-LVDS pair — TLVDS_IOBUF gives a
//   spec-compliant ~350 mV differential TX; both-leg PULL_MODE=DOWN in the
//   CST decays the AC-coupled stored offset toward zero between bursts; a
//   counter-park drives the OPPOSITE polarity for ~2.5 us after each burst
//   so the stored differential lands near zero at release (the reply's
//   SYNC-END then decodes cleanly); NO RX inversion (TLVDS sense is
//   non-inverted, opposite the ELVDS-derived convention).
//   CST REQUIREMENT:  a single differential port entry, e.g.
//                     IO_LOC  "dp_aux_p" <P_pin>,<N_pin>;
//                     IO_PORT "dp_aux_p" IO_TYPE=LVDS25 PULL_MODE=DOWN;
//   (no separate dp_aux_n CST entry — the N leg follows the pair).
//
// AUX_TLVDS=0 (legacy pseudo-differential): two single-ended LVCMOS33 pins,
//   with the board's external bias/termination network.
///////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module dp_aux_pad #(
    parameter AUX_TLVDS = 1
)(
    input  wire clk100,
    inout  wire dp_aux_p,     // LVDS pair master when AUX_TLVDS=1
    inout  wire dp_aux_n,     // LVDS pair complement
    output wire auxch_in,
    input  wire auxch_out,
    input  wire auxch_tri
);
    generate if (AUX_TLVDS != 0) begin : g_aux_tlvds
        logic auxch_in_raw;
        // Round 10: inverter REMOVED — TLVDS RX sense is non-inverted.
        assign auxch_in = auxch_in_raw;
        // Round 8 COUNTER-PARK: after the STOP, hold the OPPOSITE
        // polarity ~2.5 us (~0.5 tau of the far-side termination path)
        // so the AC-coupling caps discharge to near-zero differential
        // before release — the reply's SYNC-END then decodes cleanly.
        logic       tri_d = 1'b1;
        logic       out_last = 1'b0;
        logic [8:0] park_cnt = 9'd0;
        always_ff @(posedge clk100) begin
            tri_d <= auxch_tri;
            if (!auxch_tri)
                out_last <= auxch_out;
            if (auxch_tri && !tri_d)
                park_cnt <= 9'd250;          // 2.5 us @ 100 MHz
            else if (park_cnt != 9'd0)
                park_cnt <= park_cnt - 9'd1;
        end
        wire parking = (park_cnt != 9'd0);

        TLVDS_IOBUF i_aux_diff (
            .O   (auxch_in_raw),
            .IO  (dp_aux_p),
            .IOB (dp_aux_n),
            .I   (parking ? ~out_last : auxch_out),
            .OEN (auxch_tri && !parking)
        );
    end else begin : g_aux_pseudo
        assign dp_aux_p = auxch_tri ? 1'bz : auxch_out;
        assign dp_aux_n = auxch_tri ? 1'bz : ~auxch_out;
        assign auxch_in = dp_aux_p;
    end endgenerate
endmodule
