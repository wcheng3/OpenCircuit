#!/usr/bin/env python3
"""Try to identify f(challenge)->3 bytes from 24 known pairs by testing common constructions."""
import hashlib, zlib, itertools

PAIRS = {
    0x0f:"4bcce6",0x1f:"9bc931",0x3b:"4bee0c",0x3f:"6797a8",0x49:"0b206f",0x52:"277d7f",
    0x78:"da5d57",0x80:"a9a3ef",0x81:"4cc4ae",0x86:"db2b80",0x94:"71e959",0x96:"0860ce",
    0x9d:"6b6e2c",0xa3:"5eb61e",0xb0:"318267",0xbc:"1252f2",0xc2:"053317",0xc4:"a2f827",
    0xcb:"09889c",0xd8:"9c6191",0xda:"f01e88",0xe3:"1be985",0xe5:"520be1",0xf9:"3609b2",
}
items = list(PAIRS.items())

def hx(b): return b.hex()

# Candidate input encodings of the 1-byte challenge
def encodings(c):
    return {
        "byte": bytes([c]),
        "str": str(c).encode(),
        "hexlow": f"{c:02x}".encode(),
        "hexup": f"{c:02X}".encode(),
        "0xhex": f"0x{c:02x}".encode(),
    }

def test_hash(name, hfun):
    for enc_name in ["byte","str","hexlow","hexup","0xhex"]:
        for sl_name, sl in [("first3", slice(0,3)), ("last3", slice(-3,None))]:
            ok = all(hfun(encodings(c)[enc_name])[sl].hex()==r for c,r in items)
            if ok: print(f"  HIT: {name} {enc_name} {sl_name}")

print("=== truncated hashes (keyless) ===")
for name, h in [("md5",hashlib.md5),("sha1",hashlib.sha1),("sha224",hashlib.sha224),
                ("sha256",hashlib.sha256),("sha384",hashlib.sha384),("sha512",hashlib.sha512),
                ("sha3_256",hashlib.sha3_256),("blake2b",hashlib.blake2b),("blake2s",hashlib.blake2s)]:
    test_hash(name, lambda b, h=h: h(b).digest())

print("=== CRC variants (output = 3 bytes; try crc32 truncations + crc-any-24) ===")
# crc32 then take 3 bytes various ways
for c,r in items[:1]: pass
def crc32_variants():
    for enc in ["byte","str","hexlow","hexup"]:
        for take in ["lo3le","lo3be","hi3"]:
            def f(c, enc=enc, take=take):
                v=zlib.crc32(encodings(c)[enc]) & 0xffffffff
                b=v.to_bytes(4,"big")
                return {"lo3le":v.to_bytes(4,"little")[:3],"lo3be":b[1:4],"hi3":b[0:3]}[take]
            ok=all(hx(f(c))==r for c,r in items)
            if ok: print(f"  HIT: crc32 {enc} {take}")
crc32_variants()

# Generic CRC-24: brute common polys/inits/refin/refout/xorout
def crc24(data, poly, init, refin, refout, xorout):
    def rev(x,n):
        r=0
        for _ in range(n): r=(r<<1)|(x&1); x>>=1
        return r
    crc=init
    for byte in data:
        b=rev(byte,8) if refin else byte
        crc ^= b<<16
        for _ in range(8):
            crc<<=1
            if crc & 0x1000000: crc ^= poly
        crc &= 0xffffff
    if refout: crc=rev(crc,24)
    return (crc ^ xorout) & 0xffffff

print("=== brute CRC-24 (common polys × init × refin/out × xorout × encodings) ===")
polys=[0x864cfb,0x5d6dcb,0x328b63,0x1864cfb & 0xffffff,0x800063,0x00065b,0xC3267D,0x800FE3,0x00BAAD]
found=False
for poly in polys:
    for init in [0x000000,0xffffff,0xB704CE,0xFEDCBA,0xABCDEF]:
        for refin in (False,True):
            for refout in (False,True):
                for xorout in [0x000000,0xffffff]:
                    for enc in ["byte","str","hexlow"]:
                        ok=all(crc24(encodings(c)[enc],poly,init,refin,refout,xorout).to_bytes(3,"big").hex()==r
                               for c,r in items)
                        if ok:
                            print(f"  HIT CRC24 poly={poly:#08x} init={init:#08x} refin={refin} refout={refout} xorout={xorout:#08x} enc={enc}")
                            found=True
if not found: print("  no CRC-24 match")
print("\n(if no HIT above, f() is keyed/custom — needs the binary)")
