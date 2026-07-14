/*****************************************************************************
 * check_dp_audio.c : Independent audio SDP checker for the 2-lane frame dump
 *
 * Part of the DisplayPort_Verilog project.
 *
 * Reads the pre-scrambler symbol dump from tb_dp_frame_audio.v and, fully
 * independently of the RTL:
 *   - locates audio SDPs (single SS per lane; MSA uses double SS)
 *   - reverses the 2-lane nibble interleave
 *   - checks RS(15,13)/GF(16) parity on every header byte and every
 *     4-byte payload group (algorithm per DP 1.1a 2.2.6.1, implemented
 *     from the spec, self-tested against the spec vectors at startup)
 *   - validates Audio_TimeStamp payloads (Maud/Naud replication)
 *   - validates Audio_Stream subframes (SP/PR/V/U/C/P bits) and
 *     reconstructs the PCM ramp L[n]=n*331, R[n]=n*7919 (mod 2^16),
 *     checking sample continuity across packets
 *   - validates the Audio InfoFrame payload
 *   - confirms no stray K-codes inside SS..SE
 *
 * Exit 0 + "ALL AUDIO CHECKS PASSED" on success.
 ****************************************************************************/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SYM_BS 0x1BC
#define SYM_BE 0x1FB
#define SYM_SS 0x15C
#define SYM_SE 0x1FD

#ifndef EXPECT_MAUD
#define EXPECT_MAUD 4971        /* nominal for 48 kHz @ RBR */
#endif
#ifndef AUDIO_RATE_C
#define AUDIO_RATE_C 48000
#endif
#define EXPECT_NAUD 32768

static int errors = 0;
#define ERR(...) do { if (errors < 40) printf("ERROR: " __VA_ARGS__); errors++; } while (0)

/* ---------------- RS(15,13) over GF(16), x^4+x+1 ---------------- */
static int g0m(int c) {  /* multiply by alpha */
    return (((c>>2)&1)<<3) | (((c>>1)&1)<<2) | ((((c>>3)^c)&1)<<1) | ((c>>3)&1);
}
static int g1m(int c) {  /* multiply by alpha^4 */
    return ((((c>>3)^(c>>2))&1)<<3) | ((((c>>2)^(c>>1))&1)<<2) |
           ((((c>>3)^(c>>1)^c)&1)<<1) | (((c>>3)^c)&1);
}
static int parity_byte(const int *bytes, int n) {
    int x1 = 0, x0 = 0, i, k, nib, fb;
    for (i = 0; i < n; i++)
        for (k = 0; k < 2; k++) {
            nib = k ? (bytes[i]>>4)&0xF : bytes[i]&0xF;
            fb  = nib ^ x1;
            x1  = x0 ^ g1m(fb);
            x0  = g0m(fb);
        }
    return (x0<<4) | x1;
}
static void selftest(void) {
    /* spec vectors: nibbles fed in order == bytes lo-first */
    int v1[] = {0xEF,0xCD,0xAB,0x89};  /* f e d c b a 9 8 -> P1=2,P0=2 */
    int v2[] = {0x89,0x23,0x71,0x45};  /* 9 8 3 2 1 7 5 4 -> 8,f */
    int v3[] = {0x67,0x95,0x18,0x23};  /* 7 6 5 9 8 1 3 2 -> 7,2 */
    if (parity_byte(v1,4) != 0x22) { printf("selftest v1 fail\n"); exit(2); }
    if (parity_byte(v2,4) != 0xF8) { printf("selftest v2 fail\n"); exit(2); }
    if (parity_byte(v3,4) != 0x27) { printf("selftest v3 fail\n"); exit(2); }
}

/* ---------------- IEC 60958 channel status (matches RTL ROM) ------- */
static int chan_status_bit(int idx) {
    if (idx == 2) return 1;                 /* copyright not asserted */
    /* fs field [27:24]: 48k=0010, 44.1k=0000, 32k=0011 (matches RTL ROM) */
    if (idx == 24) return AUDIO_RATE_C == 32000;
    if (idx == 25) return AUDIO_RATE_C == 48000 || AUDIO_RATE_C == 32000;
    if (idx == 33) return 1;                /* word length [35:32]=0010 */
    return 0;
}

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
    selftest();
    if (argc < 2) { fprintf(stderr, "usage: %s dumpfile\n", argv[0]); return 2; }
    FILE *fp = fopen(argv[1], "r");
    if (!fp) { perror("open"); return 2; }

    long cap = 16000000;
    lane0 = malloc(cap*sizeof(int));
    lane1 = malloc(cap*sizeof(int));
    char buf[128];
    while (fgets(buf, sizeof buf, fp) && nsyms + 2 <= cap) {
        char a[16], b[16], c[16], d[16];
        if (sscanf(buf, "%15s %15s %15s %15s", a, b, c, d) != 4) continue;
        int s0 = parse9(a), s1 = parse9(b), s2 = parse9(c), s3 = parse9(d);
        if (s0 < 0) continue;
        lane0[nsyms] = s0;   lane1[nsyms] = s2;
        lane0[nsyms+1] = s1; lane1[nsyms+1] = s3;
        nsyms += 2;
    }
    fclose(fp);
    printf("loaded %ld symbols per lane\n", nsyms);

    long n_ts = 0, n_stream = 0, n_info = 0;
    long last_n = -1;            /* PCM ramp index */
    long iec_idx = -1;           /* IEC frame position, -1 = unknown */
    long pcm_checked = 0;

    const int WB = 24;
    for (long s = 0; s + WB + 2 < nsyms; s++) {
        if (lane0[s] != SYM_SS || lane0[s+1] == SYM_SS) continue;
        if (s > 0 && lane0[s-1] == SYM_SS) continue;   /* 2nd SS of an MSA */
        if (lane1[s] != SYM_SS) { ERR("SS not on both lanes at %ld\n", s); continue; }

        int w0[24], w1[24];
        int ok = 1;
        for (int k = 0; k < WB; k++) {
            w0[k] = lane0[s+1+k]; w1[k] = lane1[s+1+k];
            if (w0[k] >= 0x100 || w1[k] >= 0x100) {
                ERR("K-code inside SDP at %ld+%d\n", s, k); ok = 0; break;
            }
        }
        if (!ok) continue;
        if (lane0[s+1+WB] != SYM_SE || lane1[s+1+WB] != SYM_SE) {
            ERR("SE missing at %ld\n", s); continue;
        }

        /* undo nibble interleave */
        int p0[24], p1[24];
        for (int k = 0; k < WB; k++) {
            p0[k] = ((w1[k]&0xF0)) | (w0[k]&0x0F);
            p1[k] = ((w0[k]&0xF0)) | (w1[k]&0x0F);
        }

        /* header */
        int hb[4] = { p0[0], p1[0], p0[2], p1[2] };
        int pbh[4] = { p0[1], p1[1], p0[3], p1[3] };
        for (int i = 0; i < 4; i++) {
            int one[1] = { hb[i] };
            if (parity_byte(one,1) != pbh[i])
                ERR("header parity HB%d at %ld: %02X exp %02X\n",
                    i, s, pbh[i], parity_byte(one,1));
        }

        /* payload: lane0 groups 0,2,4,6; lane1 groups 1,3,5,7 */
        int db[32], pbd[8];
        for (int g = 0; g < 8; g++) {
            const int *src = (g & 1) ? p1 : p0;
            int base = 4 + (g/2)*5;
            for (int b = 0; b < 4; b++) db[4*g+b] = src[base+b];
            pbd[g] = src[base+4];
            if (parity_byte(&db[4*g],4) != pbd[g])
                ERR("payload parity g%d at %ld: %02X exp %02X\n",
                    g, s, pbd[g], parity_byte(&db[4*g],4));
        }

        /* classify */
        if (hb[1] == 0x01) {
            n_ts++;
            if (hb[0]!=0 || hb[2]!=0x17 || hb[3]!=0x44) ERR("TS header at %ld\n", s);
            for (int r = 0; r < 4; r++) {
                long m = (db[4*r]<<16)|(db[4*r+1]<<8)|db[4*r+2];
                long n = (db[16+4*r]<<16)|(db[16+4*r+1]<<8)|db[16+4*r+2];
                if (m != EXPECT_MAUD) ERR("TS Maud %ld at %ld\n", m, s);
                if (n != EXPECT_NAUD) ERR("TS Naud %ld at %ld\n", n, s);
                if (db[4*r+3] || db[16+4*r+3]) ERR("TS pad at %ld\n", s);
            }
        } else if (hb[1] == 0x02) {
            n_stream++;
            if (hb[0]!=0 || hb[2]!=0x00 || hb[3]!=0x01) ERR("Stream header at %ld\n", s);
            for (int smp = 0; smp < 4; smp++) {
                int *c1 = &db[8*smp], *c2 = &db[8*smp+4];
                int L = (c1[2]<<8)|c1[1], R = (c2[2]<<8)|c2[1];
                int b3l = c1[3], b3r = c2[3];
                if (c1[0] || c2[0]) ERR("subframe B0 not 0 at %ld\n", s);
                if (!(b3l&0x80) || !(b3r&0x80)) ERR("SP not set at %ld\n", s);
                if (((b3r>>4)&3) != 2) ERR("ch2 PR %d at %ld\n", (b3r>>4)&3, s);
                int pr_l = (b3l>>4)&3;
                if (pr_l == 0) iec_idx = 0;
                else if (iec_idx >= 0) iec_idx++;
                if (iec_idx >= 0) {
                    int c = chan_status_bit((int)(iec_idx % 192));
                    if (((b3l>>2)&1) != c) ERR("C bit at %ld (idx %ld)\n", s, iec_idx);
                    /* parity: even over sample bits + V+U+C */
                    int pl = __builtin_parity(L) ^ c;
                    if (((b3l>>3)&1) != pl) ERR("P bit L at %ld\n", s);
                    int pr_ = __builtin_parity(R) ^ c;
                    if (((b3r>>3)&1) != pr_) ERR("P bit R at %ld\n", s);
                }
                /* PCM ramp: n = L * inv(331) mod 65536; inv(331) = 32867 */
                long n = ((long)L * 32867) & 0xFFFF;
                if ((int)((n * 7919) & 0xFFFF) != R)
                    ERR("R sample mismatch at %ld (L=%04X R=%04X)\n", s, L, R);
                if (last_n >= 0 && (int)n != (int)((last_n+1)&0xFFFF))
                    ERR("sample discontinuity at %ld: n=%ld after %ld\n", s, n, last_n);
                last_n = n;
                pcm_checked++;
            }
        } else if (hb[1] == 0x84) {
            n_info++;
            if (hb[0]!=0 || hb[2]!=0x1B || hb[3]!=0x44) ERR("Info header at %ld\n", s);
            if (db[0] != 0x01) ERR("Info DB0 %02X at %ld\n", db[0], s);
            for (int i = 1; i < 32; i++)
                if (db[i]) ERR("Info DB%d nonzero at %ld\n", i, s);
        } else {
            ERR("unknown SDP type %02X at %ld\n", hb[1], s);
        }
        s += WB + 1;
    }

    printf("SDPs: %ld timestamp, %ld stream (%ld samples), %ld infoframe\n",
           n_ts, n_stream, pcm_checked, n_info);
    if (n_ts < 2)     ERR("too few timestamp packets\n");
    if (n_info < 2)   ERR("too few infoframes\n");
    if (n_stream < 100) ERR("too few stream packets\n");

    if (errors == 0) { printf("ALL AUDIO CHECKS PASSED\n"); return 0; }
    printf("%d ERRORS\n", errors);
    return 1;
}
