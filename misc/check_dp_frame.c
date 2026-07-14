/*****************************************************************************
 * check_dp_frame.c : Independent checker for the generic video front-end
 *
 * Part of the DisplayPort_Verilog project.
 *
 * Reads a pre-scrambler 2-lane symbol dump (four 9-bit binary fields per
 * line: lane0 sym0, lane0 sym1, lane1 sym0, lane1 sym1) produced by
 * tb_video_stream_packer.v and verifies:
 *
 *   - BS cadence: exactly SYMS_PER_LINE symbols between Blank Starts
 *   - VB-ID / Mvid / Maud values and vertical-blank flag sequencing
 *   - transfer-unit structure: data runs / FS..FE fill runs
 *   - pixel-exact reconstruction of full frames against the gradient
 *     r=cx&0xFF, g=cy&0xFF, b=(cx^cy)&0xFF   (2-lane pixel interleave)
 *   - MSA packet present once per frame with correct field values
 *
 * Exit code 0 and "ALL CHECKS PASSED" on success.
 ****************************************************************************/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* configuration - override with -D for other modes */
#ifndef LANES
#define LANES     2
#endif
#ifndef H_VISIBLE
#define H_VISIBLE 1280
#define V_VISIBLE 720
#define V_TOTAL   750
#define SYMS_PER_LINE 3600
#define MVID_BYTE 0xAB
#define M_VALUE   0x3AAAB
#define H_TOTAL_C 1650
#define H_SYNC_W  40
#define V_SYNC_W  5
#define H_START_C 260
#define V_START_C 25
#endif
#define N_VALUE   0x80000
#define V_TOTAL_C V_TOTAL
#ifndef MAUD_BYTE_EXP
#define MAUD_BYTE_EXP 0x000     /* expected per-line Maud byte (0 = no audio) */
#endif
#define VBID_SETS (4/LANES)
#define BYTES_PER_LANE (H_VISIBLE*3/LANES)
#define PIX_PER_LANE   (H_VISIBLE/LANES)

#define SYM_BS 0x1BC
#define SYM_BE 0x1FB
#define SYM_SS 0x15C
#define SYM_SE 0x1FD
#define SYM_FS 0x1FE
#define SYM_FE 0x1F7

static int errors = 0;
#define ERR(...) do { if (errors < 40) { printf("ERROR: " __VA_ARGS__); } \
                      errors++; } while (0)

static int *lane0, *lane1;
static long nsyms = 0;

static int parse9(const char *p) {
    int v = 0;
    for (int i = 0; i < 9; i++) {
        if (p[i] != '0' && p[i] != '1') return -1;
        v = (v << 1) | (p[i] - '0');
    }
    return v;
}

int main(int argc, char *argv[]) {
    if (argc < 2) { fprintf(stderr, "usage: %s dumpfile\n", argv[0]); return 2; }
    FILE *fp = fopen(argv[1], "r");
    if (!fp) { perror("open"); return 2; }

    long cap = 16000000;
    lane0 = malloc(cap * sizeof(int));
    lane1 = malloc(cap * sizeof(int));

    char buf[128];
    while (fgets(buf, sizeof buf, fp) && nsyms + 2 <= cap) {
        char a[16], b[16], c[16], d[16];
        if (sscanf(buf, "%15s %15s %15s %15s", a, b, c, d) != 4) continue;
        int s0 = parse9(a), s1 = parse9(b), s2 = parse9(c), s3 = parse9(d);
        if (s0 < 0 || s1 < 0 || s2 < 0 || s3 < 0) continue;
        lane0[nsyms]   = s0; lane1[nsyms]   = s2;
        lane0[nsyms+1] = s1; lane1[nsyms+1] = s3;
        nsyms += 2;
    }
    fclose(fp);
    printf("loaded %ld symbols per lane\n", nsyms);

    /* ---------------- BS cadence + VB-ID sequence ---------------- */
    long prev_bs = -1, nbs = 0, n_vb1 = 0, n_be = 0;
    int prev_vb = -1;
    long frame0_start = -1;      /* symbol index of first BE of a full frame */
    long msa_count = 0;

    for (long s = 0; s < nsyms; s++) {
        if (lane0[s] == SYM_BS) {
            if (LANES == 2 && lane1[s] != SYM_BS) ERR("BS not on both lanes at %ld\n", s);
            if (prev_bs >= 0 && s - prev_bs != SYMS_PER_LINE)
                ERR("BS spacing %ld at %ld (want %d)\n", s - prev_bs, s, SYMS_PER_LINE);
            prev_bs = s;
            nbs++;
            if (s + 3*VBID_SETS < nsyms) {
                int vb = lane0[s+1];
                for (int k = 0; k < VBID_SETS; k++) {
                    int base = (int)(3*k);
                    if (lane0[s+1+base] != vb)        ERR("VB-ID mismatch set %d at %ld\n", k, s);
                    if (lane0[s+2+base] != MVID_BYTE) ERR("Mvid byte %03X at %ld (want %02X)\n",
                                                          lane0[s+2+base], s, MVID_BYTE);
                    if (lane0[s+3+base] != MAUD_BYTE_EXP)
                        ERR("Maud byte %03X at %ld (want %03X)\n",
                            lane0[s+3+base], s, MAUD_BYTE_EXP);
                    if (LANES == 2 && (lane1[s+1+base] != vb ||
                        lane1[s+2+base] != MVID_BYTE ||
                        lane1[s+3+base] != MAUD_BYTE_EXP))
                        ERR("lane1 VBID seq differs at %ld\n", s);
                }
                /* bit4 = AudioMute is legal; other bits must be clear */
                if (vb & ~0x11) ERR("unexpected VB-ID bits %03X at %ld\n", vb, s);
                if ((vb & 1) == 1) n_vb1++;
                prev_vb = vb;
            }
        }
        if (lane0[s] == SYM_BE) {
            if (LANES == 2 && lane1[s] != SYM_BE) ERR("BE not on both lanes at %ld\n", s);
            n_be++;
            /* the BE following a vb=1 BS opens row 0 of a frame (all other
               BEs are preceded by a vb=0 BS of the previous active line) */
            if (prev_vb == 1 && frame0_start < 0 && nbs > 0)
                frame0_start = s;
        }
        if (lane0[s] == SYM_SS && s > 0 && lane0[s-1] != SYM_SS) {
            /* MSA: SS SS then 9 payload pairs then SE (lane0 view) */
            if (lane0[s+1] == SYM_SS) msa_count++;
        }
    }
    printf("BS count %ld, BE count %ld, vblank BS count %ld, MSA count %ld\n",
           nbs, n_be, n_vb1, msa_count);

    long frames_avail = nbs / V_TOTAL;
    if (frames_avail < 2) { ERR("not enough frames captured\n"); }

    /* expected per frame: V_TOTAL BS, V_VISIBLE BE, V_TOTAL-V_VISIBLE+1 vb=1 */
    if (n_be * V_TOTAL < nbs * V_VISIBLE - V_TOTAL*2)
        ERR("BE/BS ratio wrong: %ld BE for %ld BS\n", n_be, nbs);

    /* ---------------- MSA field decode (first one found) ---------------- */
    for (long s = 1; s + 24 < nsyms; s++) {
        if (lane0[s] == SYM_SS && lane0[s+1] == SYM_SS &&
            lane1[s] == SYM_SS && lane1[s+1] == SYM_SS) {
            /* lane0 payload symbols s+2.. : Mvid23:16,15:8,7:0, Htotal.. */
            /* symbol streams after the two SS symbols, per msa_inserter_2ch:
               lane0: M23:16 M15:8 M7:0 Htot_h Htot_l Vtot_h Vtot_l
                      {HsyncPol,Hsw_h} Hsw_l M23:16 M15:8 M7:0
                      Hvis_h Hvis_l Vvis_h Vvis_l 0 0
               lane1: M23:16 M15:8 M7:0 Hst_h Hst_l Vst_h Vst_l
                      {VsyncPol,Vsw_h} Vsw_l M23:16 M15:8 M7:0
                      N23:16 N15:8 N7:0 misc0 misc1 0                  */
            int p0[18], p1[18];
            for (int i = 0; i < 18; i++) { p0[i] = lane0[s+2+i]; p1[i] = lane1[s+2+i]; }
            long mvid = ((long)p0[0] << 16) | (p0[1] << 8) | p0[2];
            int htot = ((p0[3] & 0xF) << 8) | p0[4];
            int vtot = ((p0[5] & 0xF) << 8) | p0[6];
            int hsw  = ((p0[7] & 0xF) << 8) | p0[8];
            int hvis = ((p0[12] & 0xF) << 8) | p0[13];
            int vvis = ((p0[14] & 0xF) << 8) | p0[15];
            long nvid = ((long)p1[12] << 16) | (p1[13] << 8) | p1[14];
            int hstart = ((p1[3] & 0xF) << 8) | p1[4];
            int vstart = ((p1[5] & 0xF) << 8) | p1[6];
            if (mvid != M_VALUE) ERR("MSA Mvid %06lX want %06X\n", mvid, M_VALUE);
            if (htot != H_TOTAL_C) ERR("MSA Htotal %d want %d\n", htot, H_TOTAL_C);
            if (vtot != V_TOTAL_C) ERR("MSA Vtotal %d want %d\n", vtot, V_TOTAL_C);
            if (hsw  != H_SYNC_W) ERR("MSA Hsyncw %d want %d\n", hsw, H_SYNC_W);
            if (hvis != H_VISIBLE) ERR("MSA Hvis %d want %d\n", hvis, H_VISIBLE);
            if (vvis != V_VISIBLE) ERR("MSA Vvis %d want %d\n", vvis, V_VISIBLE);
            if (hstart != H_START_C) ERR("MSA Hstart %d want %d\n", hstart, H_START_C);
            if (vstart != V_START_C) ERR("MSA Vstart %d want %d\n", vstart, V_START_C);
            if (nvid != N_VALUE) ERR("MSA Nvid %06lX want %06X\n", nvid, N_VALUE);
            printf("MSA decode ok at %ld (Mvid %06lX Nvid %06lX %dx%d)\n",
                   s, mvid, nvid, hvis, vvis);
            break;
        }
    }

    /* ---------------- pixel reconstruction of one full frame ------------ */
    if (frame0_start < 0) { ERR("no frame boundary found\n"); }
    else {
        long s = frame0_start;
        int row = 0, ok = 1;
        long pix_errors = 0;
        while (row < V_VISIBLE && s < nsyms) {
            /* find next BE */
            while (s < nsyms && lane0[s] != SYM_BE) s++;
            if (s >= nsyms) { ERR("ran out of symbols at row %d\n", row); break; }
            s++;
            /* collect the line's data bytes per lane, skipping FS..FE fills */
            int b0[BYTES_PER_LANE], b1[BYTES_PER_LANE];
            int n0 = 0, in_fill = 0;
            while (n0 < BYTES_PER_LANE && s < nsyms) {
                int c0 = lane0[s], c1 = lane1[s];
                if (c0 == SYM_FS) { in_fill = 1; }
                else if (c0 == SYM_FE) { in_fill = 0; }
                else if (c0 == SYM_BS) { ERR("BS before line data complete row %d (%d bytes)\n", row, n0); break; }
                else if (!in_fill && c0 < 0x100) {
                    b0[n0] = c0; b1[n0] = c1; n0++;
                } else if (!in_fill && c0 >= 0x100) {
                    ERR("unexpected K-code %03X in data region row %d\n", c0, row);
                    break;
                }
                s++;
            }
            if (n0 != BYTES_PER_LANE) { ok = 0; break; }
            /* pixel interleave: lane N carries pixels N, N+LANES, ... R,G,B */
            for (int p = 0; p < PIX_PER_LANE; p++) {
                for (int ln = 0; ln < LANES; ln++) {
                    int *b = ln ? b1 : b0;
                    int cxp = LANES*p + ln;
                    int er = cxp & 0xFF, eg = row & 0xFF, eb = (cxp ^ row) & 0xFF;
                    if (b[3*p] != er || b[3*p+1] != eg || b[3*p+2] != eb) {
                        if (pix_errors < 10)
                            ERR("pixel (%d,%d) lane%d got %02X%02X%02X want %02X%02X%02X\n",
                                cxp, row, ln, b[3*p], b[3*p+1], b[3*p+2], er, eg, eb);
                        pix_errors++;
                    }
                }
            }
            row++;
        }
        if (ok && row == V_VISIBLE && pix_errors == 0)
            printf("frame reconstruction: %d rows pixel-exact\n", row);
        else
            ERR("frame reconstruction failed: rows %d pixel errors %ld\n", row, pix_errors);
    }

    if (msa_count < frames_avail - 1)
        ERR("MSA count %ld too low for %ld frames\n", msa_count, frames_avail);

    if (errors == 0) { printf("ALL CHECKS PASSED\n"); return 0; }
    printf("%d ERRORS\n", errors);
    return 1;
}
