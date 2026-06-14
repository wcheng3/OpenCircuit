#!/usr/bin/env python3
"""Decode the RingConn Gen 2 bulk activity/sleep stream (`0x4c` pages).

Reads the text output of `python -m openringconn decode-log <btsnoop>` and
reassembles the `0x4c` record stream into per-epoch records, converting the
24-bit counter to wall-clock via the §5.6 epoch.

Each 0x4c notification: [0]=0x4c [1]=00 [2]=remaining-record countdown,
then 6 x 23-byte records, then a 1-byte XOR trailer. Records concatenate
across packets (strip the 3-byte header AND the 1-byte trailer per packet).

Record (23 B), confirmed against captures/sleep_sync_btsnoop.log (FR02.018):
  [0:4]   big-endian counter, +0x96 (150) per record  -> 150 s epochs
  [4:8]   4-byte field (varies; secondary counter / packed) 🟡
  [8]     subtype tag: 0x12 common; 0x5a-0x63 periodic markers 🟡
  [9]     small int (mostly 0x0a) 🟡
  [10:15] 5 x per-30 s MOTION/activity counts (decays awake->asleep) 🟢-ish
  [15:22] 7-byte per-epoch physiology payload (HR/HRV/SpO2?) 🟡
  [22]    trailer flags 🟡

Usage:
  python -m openringconn decode-log captures/foo.log --addr <mac> > /tmp/dec.txt
  python decode_bulk.py /tmp/dec.txt
"""
import re
import sys
import datetime

EPOCH = 1577793600  # §5.6: 2019-12-31 12:00:00 UTC
RECLEN = 23
STEP = 0x96  # 150 s


def notif_payloads(lines, opcode):
    out = []
    for ln in lines:
        m = re.search(r"Notification\s+0x0804\s+(.*)$", ln)
        if not m:
            continue
        b = bytes(int(x, 16) for x in m.group(1).split())
        if b and b[0] == opcode:
            out.append(b)
    return out


def reassemble_4c(payloads):
    """Strip 3-byte header + 1-byte XOR trailer per packet, concat, split to records."""
    stream = b"".join(p[3:-1] for p in payloads)
    return [stream[i:i + RECLEN] for i in range(0, len(stream), RECLEN)
            if len(stream[i:i + RECLEN]) == RECLEN]


def ts(counter):
    return datetime.datetime.utcfromtimestamp(counter + EPOCH)


def is_idle(r):
    return r[10:15] == bytes([1, 1, 1, 1, 1]) and r[15:22] == bytes(7)


def main(path):
    lines = open(path).read().splitlines()
    recs = reassemble_4c(notif_payloads(lines, 0x4c))
    if not recs:
        print("no 0x4c records found", file=sys.stderr)
        return 1
    print(f"{len(recs)} records ({sum(is_idle(r) for r in recs)} idle)\n")

    # segment into sessions (gap > 600 s)
    prev = None
    seg = []
    sessions = []
    for r in recs:
        c = int.from_bytes(r[0:4], "big")
        if prev is not None and c - prev > 600:
            sessions.append(seg)
            seg = []
        seg.append(r)
        prev = c
    sessions.append(seg)

    for s in sessions:
        c0 = int.from_bytes(s[0][0:4], "big")
        c1 = int.from_bytes(s[-1][0:4], "big")
        worn = sum(1 for r in s if not is_idle(r))
        print(f"== session {ts(c0)} -> {ts(c1)} UTC | {len(s)} epochs, "
              f"{worn} worn / {len(s)-worn} idle ==")
        for r in s:
            c = int.from_bytes(r[0:4], "big")
            mot = r[10:15]
            msum = sum(v for v in mot if v != 1)
            tag = "IDLE" if is_idle(r) else f"{r[8]:#04x}"
            bar = "#" * min(msum, 40)
            print(f"  {ts(c):%H:%M}  mot={mot.hex()} phys={r[15:22].hex()} "
                  f"{tag:>4} {bar}")
        print()
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
