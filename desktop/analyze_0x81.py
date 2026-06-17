#!/usr/bin/env python3
"""Issue #4: is `81 00 <XX> <xor>` byte[2] a session token or battery %?

For every decoded capture given on argv (or a default set), find:
  - every `81 00 XX YY` notification (response to `01 00 00`) and its byte[2],
  - the surrounding session boundary (each new connection / status handshake),
  - the battery % from any `0x10`/`0x87`/`0x4c` descriptor byte[1] in the SAME
    capture, so byte[2] can be cross-checked against a known battery level.

Within a single session the FIRST `01 00 00` is the cold status read; the app may
issue more `01 00 00` later. We report byte[2] per occurrence AND per session so
"constant within a session" can be judged.

Battery cross-check: PROTOCOL.md §5.4 says `0x10`/`0x87` byte[1] = battery %.
We pull those too and report the battery seen in each capture.

Usage: python analyze_0x81.py [decoded.txt ...]
"""
from __future__ import annotations
import sys, glob, os

def hexbytes(tail: str) -> list[int]:
    out = []
    for t in tail.split():
        if len(t) == 2:
            try:
                out.append(int(t, 16))
            except ValueError:
                break
        else:
            break
    return out

def parse(path: str):
    """Yield (time, dir, conn, op, handle, payload[list[int]]) for each line."""
    rows = []
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if "Notification" not in line and "WriteReq" not in line:
                continue
            parts = line.split()
            if len(parts) < 5:
                continue
            t = parts[0]
            d = parts[1]
            conn = parts[2]
            op = parts[3]
            # handle column may be '—' or 0xXXXX; payload after it
            # find the index where hex payload begins: look for handle token
            # layout: time dir conn op handle payload...
            # but op can be multi? In decode it's single token (Notification/WriteReq/...)
            try:
                idx = 4
                handle = parts[idx]
                payload = hexbytes(" ".join(parts[idx+1:]))
            except IndexError:
                continue
            rows.append((t, d, conn, op, handle, payload))
    return rows

def main():
    paths = sys.argv[1:]
    if not paths:
        paths = sorted(glob.glob("captures/*_decoded.txt"))
    print(f"{'capture':32} {'time':12} {'conn':6} {'81[2]':>6} {'hex':>14}")
    print("-" * 80)
    summary = {}
    for path in paths:
        name = os.path.basename(path).replace("_decoded.txt", "")
        rows = parse(path)
        # battery from descriptors
        batt = []
        for (t, d, conn, op, handle, pl) in rows:
            if d == "RX" and pl and pl[0] in (0x10, 0x87) and len(pl) >= 2:
                batt.append((t, pl[1]))
        # 81 00 frames
        b2s = []
        # also track session: a new "01 00 00" TX precedes the 81 00
        last_status_tx = None
        for (t, d, conn, op, handle, pl) in rows:
            if d == "TX" and pl[:3] == [0x01, 0x00, 0x00]:
                last_status_tx = (t, conn)
            if d == "RX" and pl[:2] == [0x81, 0x00] and len(pl) >= 4:
                xx = pl[2]
                xor = pl[3]
                calc = pl[0] ^ pl[1] ^ pl[2]
                ok = "ok" if calc == xor else f"BAD(want {calc:02x})"
                hexs = " ".join(f"{b:02x}" for b in pl[:4])
                print(f"{name:32} {t:12} {conn:6} {xx:6d} {hexs:>14}  xor={ok}")
                b2s.append((t, conn, xx))
        summary[name] = (b2s, batt)
    print()
    print("=" * 80)
    print("PER-CAPTURE SUMMARY")
    print("=" * 80)
    for name, (b2s, batt) in summary.items():
        if not b2s and not batt:
            continue
        xx_vals = [x[2] for x in b2s]
        batt_vals = sorted(set(b[1] for b in batt))
        print(f"\n{name}:")
        print(f"  81 00 byte[2] occurrences ({len(xx_vals)}): {xx_vals}")
        if xx_vals:
            print(f"    distinct={sorted(set(xx_vals))}  min={min(xx_vals)} max={max(xx_vals)} >100 count={sum(1 for v in xx_vals if v>100)}")
        # per-conn (session) grouping
        byconn = {}
        for (t, conn, xx) in b2s:
            byconn.setdefault(conn, []).append(xx)
        for conn, vals in byconn.items():
            const = "CONSTANT" if len(set(vals)) == 1 else "VARIES"
            print(f"    conn {conn}: {vals}  -> {const} within this connection-handle")
        if batt:
            print(f"  battery (0x10/0x87 byte[1]) distinct: {batt_vals}  (first={batt[0][1]} last={batt[-1][1]}, n={len(batt)})")
        else:
            print(f"  battery: NONE in this capture")

if __name__ == "__main__":
    main()
