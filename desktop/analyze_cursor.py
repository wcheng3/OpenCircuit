#!/usr/bin/env python3
"""Pin the 0x02 sync-cursor semantics from a decoded official-app capture.

For each sync the app does (an `02 00 <cursor> <flag> 01 00` open), report:
  - the open cursor,
  - the counter RANGE of the records the ring actually returned (0x4c and 0x47),
  - the 0x50 end-of-history frame(s).

The record 4-byte value is [0c][3-byte counter], the SAME shape as the cursor
(PROTOCOL.md §3), so they're directly comparable. This tells us what "open at
cursor X" really returns — the question my incremental-cursor fix got wrong.

Usage: python analyze_cursor.py captures/ppg_align_20260616_decoded.txt
"""
from __future__ import annotations
import sys

def toks_after(line: str, marker: str) -> list[int]:
    if marker not in line:
        return []
    tail = line.split(marker, 1)[1].strip()
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

def records(body: list[int], opcode: int, rec_len: int) -> list[int]:
    """Return the 4-byte [0c|3-counter] values of each record in a page body."""
    if len(body) < 4 or body[0] != opcode:
        return []
    recs = body[3:-1]  # drop [op][00][countdown] and trailing xor
    out = []
    for off in range(0, len(recs) - rec_len + 1, rec_len):
        r = recs[off:off + rec_len]
        if r[0] == 0x0c:
            out.append((r[0] << 24) | (r[1] << 16) | (r[2] << 8) | r[3])
    return out

def main() -> None:
    path = sys.argv[1] if len(sys.argv) > 1 else "captures/ppg_align_20260616_decoded.txt"
    syncs = []          # each: dict(open, flag, c4=[], c47=[], eoh=[])
    cur = None
    with open(path) as f:
        for line in f:
            if "0802 02 00" in line:                      # sync-open
                b = toks_after(line, "0x0802")
                if len(b) >= 7 and b[0] == 0x02:
                    cursor = (b[2] << 24) | (b[3] << 16) | (b[4] << 8) | b[5]
                    cur = dict(open=cursor, flag=b[6], c4=[], c47=[], eoh=[])
                    syncs.append(cur)
                continue
            if cur is None:
                continue
            if "0x0804 4c " in line:
                cur["c4"] += records(toks_after(line, "0x0804"), 0x4c, 23)
            elif "0x0804 47 " in line:
                cur["c47"] += records(toks_after(line, "0x0804"), 0x47, 47)
            elif "0x0804 50 " in line:
                cur["eoh"].append(toks_after(line, "0x0804"))

    def rng(xs):
        return f"{min(xs):08x}..{max(xs):08x}" if xs else "—"

    print(f"{path}: {len(syncs)} syncs\n")
    print(f"{'open cursor':>10}  fl  {'#4c':>4} {'4c counter range':>20}  {'#47':>4} {'47 counter range':>20}  rel")
    for s in syncs:
        allc = s["c4"] + s["c47"]
        if allc:
            mn, mx = min(allc), max(allc)
            # where does the open cursor sit vs the returned records?
            if s["open"] < mn:   rel = "open < all recs"
            elif s["open"] > mx: rel = f"open > all recs (+{s['open']-mx})"
            else:                rel = "open INSIDE range"
        else:
            rel = "no records"
        print(f"{s['open']:08x}  {s['flag']:02x}  {len(s['c4']):>4} {rng(s['c4']):>20}  "
              f"{len(s['c47']):>4} {rng(s['c47']):>20}  {rel}")
    # show the 0x50 frames distinctly
    print("\n0x50 end-of-history frames seen (sub-byte after 50 00 00 → cursor entries):")
    seen = set()
    for s in syncs:
        for e in s["eoh"]:
            key = tuple(e)
            if key in seen:
                continue
            seen.add(key)
            print("  " + " ".join(f"{x:02x}" for x in e))

if __name__ == "__main__":
    main()
