#!/usr/bin/env python3
"""
Analyze capture files to resolve GitHub issues #3, #5, and #4.

#3 – Counter time unit: confirm +0x96 = 150s per 0x4c record.
#5 – 12h offset: compare decoded counter wall-clock to capture timestamps.
#4 – 0x81 byte[2]: token or battery?

Run from desktop/:
    python analyze_counters.py
"""

from __future__ import annotations
import struct, sys, os
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(__file__))
from opencircuit.sniff import _iter_att

RING_EPOCH = 1577793600  # 2019-12-31 12:00:00 UTC
CAPTURES = os.path.join(os.path.dirname(__file__), "captures")


def decode_cursor(data: bytes, off: int) -> int:
    """Read a 4-byte BE cursor starting at `off`."""
    return struct.unpack_from(">I", data, off)[0]


def cursor_to_utc(cursor: int) -> datetime:
    return datetime.fromtimestamp(RING_EPOCH + cursor, tz=timezone.utc)


def analyze_file(path: str) -> None:
    print(f"\n{'='*70}")
    print(f"FILE: {os.path.basename(path)}")
    print(f"{'='*70}")

    with open(path, "rb") as f:
        blob = f.read()

    events = list(_iter_att(blob))

    # ── Issue #4: 0x81 00 byte[2] ────────────────────────────────────────────
    print("\n── Issue #4: 0x81 00 byte[2] across all sessions ──")
    print(f"  {'time_utc':<15} {'conn':<6} {'byte[2]':>8} {'hex':>5}")
    status_vals = []
    for ev in events:
        if not ev.sent and ev.opcode == 0x1B and ev.value[:2] == bytes([0x81, 0x00]):
            ts = datetime.fromtimestamp(ev.ts_unix, tz=timezone.utc)
            b2 = ev.value[2] if len(ev.value) >= 3 else None
            if b2 is not None:
                status_vals.append((ev.ts_unix, ev.conn_handle, b2))
                print(f"  {ts.strftime('%H:%M:%S'):<15} 0x{ev.conn_handle:03x}  "
                      f"{b2:>8}   0x{b2:02x}")
    if status_vals:
        vals = [x[2] for x in status_vals]
        print(f"  min={min(vals)} max={max(vals)} range={max(vals)-min(vals)}"
              f" (>100 → cannot be battery%; full 8-bit range)")
        # Check if any same-connection repeated
        from collections import Counter
        conn_counts = Counter(x[1] for x in status_vals)
        multi = {h: [x[2] for x in status_vals if x[1] == h]
                 for h, c in conn_counts.items() if c > 1}
        if multi:
            print("  Same-connection multiple reads:")
            for h, vs in multi.items():
                print(f"    conn 0x{h:03x}: {vs}")

    # ── Issue #3 & #5: counter analysis ──────────────────────────────────────
    print("\n── Issue #3/#5: 0x4c record counters ──")
    four_c_records = []  # list of (unix_ts, cursor)
    for ev in events:
        if not ev.sent and ev.opcode == 0x1B and ev.value and ev.value[0] == 0x4c:
            # Page: [0]=4c [1]=00 [2]=countdown [3:]=body
            body = ev.value[3:]  # body has 6×23-byte records each starting 0c
            pos = 0
            while pos + 23 <= len(body):
                if body[pos] != 0x0c:
                    break
                # [1:5] = 4-byte BE cursor (0c is the first byte of the 4-byte cursor)
                cursor = decode_cursor(bytes([0x0c]) + body[pos+1:pos+4], 0)
                four_c_records.append((ev.ts_unix, cursor))
                pos += 23

    if four_c_records:
        print(f"  Total 0x4c records decoded: {len(four_c_records)}")
        # Show first and last
        ts_first, c_first = four_c_records[0]
        ts_last, c_last = four_c_records[-1]
        dt_first = cursor_to_utc(c_first)
        dt_last = cursor_to_utc(c_last)
        print(f"  First record: cursor=0x{c_first:08x} → {dt_first}")
        print(f"  Last  record: cursor=0x{c_last:08x} → {dt_last}")

        # Check counter steps
        steps = []
        for i in range(1, min(30, len(four_c_records))):
            delta = four_c_records[i][1] - four_c_records[i-1][1]
            steps.append(delta)
        from collections import Counter
        step_counts = Counter(steps)
        print(f"  Counter steps (first 29): {dict(step_counts.most_common(5))}")
        print(f"  0x96=150? Matches: {step_counts.get(0x96, 0)}/{len(steps)}")

        # Issue #5: Does the decoded counter time match capture wall-clock?
        # Use the sync-open TX event to anchor
        print("\n── Issue #5: counter vs capture wall-clock ──")
        # Find sync-open command (TX: 02 00 <cursor:4> ...)
        for ev in events:
            if ev.sent and ev.opcode == 0x12 and ev.att_handle == 0x0802:
                if ev.value and ev.value[0] == 0x02 and len(ev.value) >= 6:
                    cursor_bytes = ev.value[2:6]  # bytes 2-5 of the write value
                    sync_cursor = struct.unpack_from(">I", cursor_bytes, 0)[0]
                    if sync_cursor != 0xFFFFFFFF:  # skip the "all" cursor
                        cap_ts = datetime.fromtimestamp(ev.ts_unix, tz=timezone.utc)
                        ring_ts = cursor_to_utc(sync_cursor)
                        diff_s = ring_ts.timestamp() - ev.ts_unix
                        print(f"  Sync-open TX at cap-time {cap_ts}")
                        print(f"  Cursor 0x{sync_cursor:08x} → ring-time {ring_ts}")
                        print(f"  Difference: {diff_s:.1f} s ({diff_s/3600:.2f} h)")
                        if abs(diff_s) < 600:
                            print(f"  → No 12 h offset; counter tracks UTC wall-clock. 🟢")
                        elif abs(diff_s - 43200) < 600 or abs(diff_s + 43200) < 600:
                            print(f"  → 12 h offset CONFIRMED. 🟡")
                        else:
                            print(f"  → Unexpected offset: {diff_s/3600:.2f} h")

        # Also check 0x50 end-of-history
        print("\n── 0x50 end-of-history cursors ──")
        for ev in events:
            if not ev.sent and ev.opcode == 0x1B and ev.value and ev.value[0] == 0x50:
                payload = ev.value  # 50 00 00 | entries
                cap_ts = datetime.fromtimestamp(ev.ts_unix, tz=timezone.utc)
                print(f"  At {cap_ts.strftime('%H:%M:%S')} (cap), raw: {payload.hex(' ')[:60]}")
                # entries of 6B: [type][sub][cursor:4]
                pos = 3
                while pos + 6 <= len(payload):
                    entry_type = payload[pos]
                    entry_sub = payload[pos+1]
                    c = decode_cursor(payload, pos+2)
                    ring_ts = cursor_to_utc(c)
                    print(f"    type=0x{entry_type:02x} sub=0x{entry_sub:02x} "
                          f"cursor=0x{c:08x} → {ring_ts}")
                    pos += 6

    # ── Issue #3: 0x47 counter steps ────────────────────────────────────────
    print("\n── Issue #3: 0x47 counter steps ──")
    four_seven_records = []
    for ev in events:
        if not ev.sent and ev.opcode == 0x1B and ev.value and ev.value[0] == 0x47:
            body = ev.value[3:]
            pos = 0
            while pos + 47 <= len(body):
                if body[pos] != 0x0c:
                    break
                cursor = decode_cursor(bytes([0x0c]) + body[pos+1:pos+4], 0)
                four_seven_records.append(cursor)
                pos += 47
    if four_seven_records:
        steps47 = [four_seven_records[i] - four_seven_records[i-1]
                   for i in range(1, min(20, len(four_seven_records)))]
        from collections import Counter as C2
        sc = C2(steps47)
        print(f"  0x47 records: {len(four_seven_records)}, counter steps: {dict(sc.most_common(5))}")
        print(f"  0x384=900? Matches: {sc.get(0x384, 0)}/{len(steps47)}")


if __name__ == "__main__":
    files = [
        "morning_temp_20260615_btsnoop.log",
        "sleep_sync_btsnoop.log",
        "btsnoop_hr.log",
        "fresh_btsnoop.log",
    ]
    for fname in files:
        path = os.path.join(CAPTURES, fname)
        if os.path.exists(path):
            analyze_file(path)
        else:
            print(f"\nSKIP (not found): {fname}")
