#!/usr/bin/env python3
"""DP SDP golden model: RS(15,13)/GF(16) ECC + nibble interleave + wire packing.
Verified against VESA DP 1.1a section 2.2.6 test vectors."""

def gfmul_1(a):  # multiply by alpha   (g0)
    c=[(a>>i)&1 for i in range(4)]
    g=[c[3], c[0]^c[3], c[1], c[2]]
    return sum(g[i]<<i for i in range(4))

def gfmul_4(a):  # multiply by alpha^4 (g1)
    c=[(a>>i)&1 for i in range(4)]
    g=[c[0]^c[3], c[0]^c[1]^c[3], c[1]^c[2], c[2]^c[3]]
    return sum(g[i]<<i for i in range(4))

def rs_parity_nibbles(nibs):
    """Shift data nibbles (first = highest-degree) through the LFSR.
       Returns (P1, P0); P1 transmitted first = Par(3:0), P0 = Par(7:4)."""
    x0 = x1 = 0
    for n in nibs:
        fb = (n ^ x1) & 0xF
        x1 = x0 ^ gfmul_4(fb)
        x0 = gfmul_1(fb)
    return x1, x0

def parity_byte(data_bytes):
    """Parity byte over 1 header byte or 4 payload bytes.
       Nibble order into LFSR: low nibble of each byte first."""
    nibs=[]
    for b in data_bytes:
        nibs += [b & 0xF, (b >> 4) & 0xF]
    p1, p0 = rs_parity_nibbles(nibs)
    return (p0 << 4) | p1          # Par(7:4)=P0, Par(3:0)=P1

def hi(b): return (b>>4)&0xF
def lo(b): return b&0xF

def swap_hi(a, b):
    """2/4-lane interleave primitive: lanes swap high nibbles."""
    return ((hi(b)<<4)|lo(a), (hi(a)<<4)|lo(b))

def sdp_wire_2lane(hb, payload):
    """hb = [HB0..HB3]; payload padded to multiple of 16 bytes.
       Returns (lane0_bytes, lane1_bytes) EXCLUDING SS/SE."""
    assert len(payload) % 16 == 0
    pb = [parity_byte([b]) for b in hb]      # PB0..PB3
    l0, l1 = [], []
    # header: HB0/HB1 + PB0/PB1, then HB2/HB3 + PB2/PB3
    for pair, ppair in (((hb[0],hb[1]),(pb[0],pb[1])), ((hb[2],hb[3]),(pb[2],pb[3]))):
        a,b   = swap_hi(*pair);  l0.append(a); l1.append(b)
        a,b   = swap_hi(*ppair); l0.append(a); l1.append(b)
    # payload: per 16-byte block: lane0 gets bytes 0-3 then 8-11; lane1 gets 4-7 then 12-15
    for blk in range(0, len(payload), 16):
        B = payload[blk:blk+16]
        for g0_, g1_ in (((0,4)), ((8,12))):
            d0 = B[g0_:g0_+4]; d1 = B[g1_:g1_+4]
            q0 = parity_byte(d0); q1 = parity_byte(d1)
            for k in range(4):
                a,b = swap_hi(d0[k], d1[k]); l0.append(a); l1.append(b)
            a,b = swap_hi(q0, q1); l0.append(a); l1.append(b)
    return l0, l1

def sdp_wire_1lane(hb, payload):
    """Returns lane0 byte list EXCLUDING SS/SE."""
    assert len(payload) % 16 == 0
    pb = [parity_byte([b]) for b in hb]
    out=[]
    # header: pairs (HB0,HB1), (HB2,HB3); Fig 2-29 interleave
    for i in (0,2):
        h0,h1 = hb[i],hb[i+1]; q0,q1 = pb[i],pb[i+1]
        out.append((lo(h1)<<4)|lo(h0))       # {HB1.lo, HB0.lo}
        out.append((lo(q1)<<4)|lo(q0))       # {PBi+1.lo, PBi.lo}
        out.append((hi(h0)<<4)|hi(h1))       # {HB0.hi, HB1.hi}
        out.append((hi(q0)<<4)|hi(q1))       # {PBi.hi, PBi+1.hi}
    # payload: per 8-byte group (Fig 2-27)
    for g in range(0, len(payload), 8):
        D = payload[g:g+8]
        q0 = parity_byte(D[0:4]); q1 = parity_byte(D[4:8])
        for k in range(4):
            out.append((lo(D[k+4])<<4)|lo(D[k]))   # {D[k+4].lo, D[k].lo}
        out.append((lo(q1)<<4)|lo(q0))
        for k in range(4):
            out.append((hi(D[k])<<4)|hi(D[k+4]))   # {D[k].hi, D[k+4].hi}
        out.append((hi(q0)<<4)|hi(q1))
    return out

if __name__ == "__main__":
    # spec test vectors (2.2.6.1)
    for msg,par in [([0xf,0xe,0xd,0xc,0xb,0xa,0x9,0x8],(2,2)),
                    ([0x9,0x8,0x3,0x2,0x1,0x7,0x5,0x4],(8,0xf)),
                    ([0x7,0x6,0x5,0x9,0x8,0x1,0x3,0x2],(7,2))]:
        assert rs_parity_nibbles(msg)==par, (msg,par)
    print("spec vectors OK")
    print("header parity bytes:")
    for b in (0x00,0x01,0x02,0x17,0x1B,0x44,0x84):
        print(f"  PB(HB=0x{b:02X}) = 0x{parity_byte([b]):02X}")
    # Audio TimeStamp example: 48 kHz @ 2.70 Gbps -> Maud=512(0x000200), Naud=5625(0x0015F9)
    hb=[0x00,0x01,0x17,0x44]
    m=[0x00,0x02,0x00,0x00]  # Maud23:16, Maud15:8, Maud7:0, All-0
    n=[0x00,0x15,0xF9,0x00]
    payload = m*4 + n*4      # 32 bytes on the wire
    print("\nAudio_TimeStamp 48kHz@2.7G, 2-lane wire bytes (after SS, before SE):")
    l0,l1 = sdp_wire_2lane(hb,payload)
    print("  lane0:", " ".join(f"{b:02X}" for b in l0))
    print("  lane1:", " ".join(f"{b:02X}" for b in l1))
    print("Audio_TimeStamp 48kHz@2.7G, 1-lane wire bytes:")
    w = sdp_wire_1lane(hb,payload)
    print("  lane0:", " ".join(f"{b:02X}" for b in w))
    # Audio_Stream example: 2ch 16-bit LPCM, sample L=0x1234, R=0xABCD, first sample of IEC block
    hb=[0x00,0x02,0x00,0x01]
    def subframe(s16, pr, first_of_block):
        w24 = (s16<<8) & 0xFFFFFF   # left-justify 16-bit into 24-bit, LSBs zero
        b0 =  w24      & 0xFF       # LSBs of audio word
        b1 = (w24>>8)  & 0xFF
        b2 = (w24>>16) & 0xFF       # MSBs
        # byte3: SP=1, R=0, PR, P=0,C=0,U=0,V=0
        b3 = 0x80 | (pr<<4)
        return [b0,b1,b2,b3]
    s0 = subframe(0x1234, 0b00, True) + subframe(0xABCD, 0b10, True)   # PR: 00=start of block ch1, 10=subframe2
    s1 = subframe(0x5678, 0b01, False) + subframe(0xEF01, 0b10, False) # PR: 01=subframe1, 10=subframe2
    payload = s0 + s1
    print("\nAudio_Stream 2ch (S0 L=0x1234 R=0xABCD blockstart, S1 L=0x5678 R=0xEF01), 2-lane wire:")
    l0,l1 = sdp_wire_2lane(hb,payload)
    print("  lane0:", " ".join(f"{b:02X}" for b in l0))
    print("  lane1:", " ".join(f"{b:02X}" for b in l1))
    print("Audio_Stream same packet, 1-lane wire:")
    w = sdp_wire_1lane(hb,payload)
    print("  lane0:", " ".join(f"{b:02X}" for b in w))
