#!/usr/bin/env python3
"""Locate the RingConn auth table f(challenge)->3 bytes inside libapp.so by spacing.

If f() is a flat challenge-indexed byte table, response(c) sits at base + c*stride.
We know 24 (challenge,response) pairs; find a (base,stride) that explains many of them.
"""
import sys

PAIRS = {
    0x0f:(0x4b,0xcc,0xe6),0x1f:(0x9b,0xc9,0x31),0x3b:(0x4b,0xee,0x0c),0x3f:(0x67,0x97,0xa8),
    0x49:(0x0b,0x20,0x6f),0x52:(0x27,0x7d,0x7f),0x78:(0xda,0x5d,0x57),0x80:(0xa9,0xa3,0xef),
    0x81:(0x4c,0xc4,0xae),0x86:(0xdb,0x2b,0x80),0x94:(0x71,0xe9,0x59),0x96:(0x08,0x60,0xce),
    0x9d:(0x6b,0x6e,0x2c),0xa3:(0x5e,0xb6,0x1e),0xb0:(0x31,0x82,0x67),0xbc:(0x12,0x52,0xf2),
    0xc2:(0x05,0x33,0x17),0xc4:(0xa2,0xf8,0x27),0xcb:(0x09,0x88,0x9c),0xd8:(0x9c,0x61,0x91),
    0xda:(0xf0,0x1e,0x88),0xe3:(0x1b,0xe9,0x85),0xe5:(0x52,0x0b,0xe1),0xf9:(0x36,0x09,0xb2),
}

def find_all(data, pat):
    out, i = [], data.find(pat)
    while i != -1:
        out.append(i); i = data.find(pat, i+1)
    return out

def main():
    data = open(sys.argv[1] if len(sys.argv)>1 else "lib/arm64-v8a/libapp.so","rb").read()
    print(f"{len(data)} bytes")
    occ = {c: find_all(data, bytes(t)) for c,t in PAIRS.items()}
    for c,offs in sorted(occ.items()):
        if not offs: print(f"  challenge {c:#04x} {bytes(PAIRS[c]).hex()} : NOT FOUND")
    # Try strides; anchor on each occurrence of challenge 0xb0, hypothesize base, count hits.
    best=None
    for stride in (1,2,3,4,8):
        for anchor_c,anchor_offs in occ.items():
            for ao in anchor_offs:
                base = ao - anchor_c*stride
                if base < 0: continue
                hits = []
                for c,t in PAIRS.items():
                    pos = base + c*stride
                    if 0 <= pos <= len(data)-3 and data[pos:pos+3]==bytes(t):
                        hits.append(c)
                if best is None or len(hits) > len(best[2]):
                    best = (base, stride, hits)
    base,stride,hits = best
    print(f"\nBEST: base={base:#x} stride={stride}  explains {len(hits)}/{len(PAIRS)} known pairs: {[hex(h) for h in sorted(hits)]}")
    if len(hits) >= 6:
        print(f"\n>>> TABLE FOUND. Dumping 256 entries (stride {stride}) from base {base:#x}:")
        tbl = {}
        for c in range(256):
            pos = base + c*stride
            tbl[c] = data[pos:pos+3].hex()
        # sanity: all known pairs match?
        ok = all(tbl[c]==bytes(t).hex() for c,t in PAIRS.items())
        print(f"all 24 known pairs match table: {ok}")
        for c in range(256):
            end = " " if (c%8)!=7 else "\n"
            print(f"{c:02x}:{tbl[c]}", end=end)
    else:
        print("No flat byte-table found (f() is likely computed, not a table).")

if __name__=="__main__":
    main()
