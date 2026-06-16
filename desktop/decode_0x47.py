#!/usr/bin/env python3
"""Decode 0x47 PPG payloads from a decoded-capture txt and prep them for #8 alignment.

#8 = "Capture: realtime PPG alignment -> decode 0x47 payload". Geometry is 🟢 (47-byte
records, +0x384 counter, 38-byte payload at record[9:47]); the SAMPLE decode (bit width +
channel) is 🔴 and can ONLY be proven by aligning to an external reference (the official
app's PPG trace + a deliberate finger-on/off sequence + a reference HR). This tool does the
mechanical part: extract records, decode the payload BOTH plausible ways (10-bit and 12-bit
big-endian), and emit per-record amplitude + CSVs so the on->off amplitude collapse can be
overlaid on the finger-off timestamps.

⚠️ It does NOT prove anything on its own. A "smooth"/"self-consistent" array is NOT evidence
(see #8 pitfalls + the project no-fabrication rule). Run it on a FIDUCIAL capture and align.

Usage:
  # 1. turn the btsnoop into a decoded txt with the existing tool:
  python -m openringconn decode-log captures/ppg_align_btsnoop.log > captures/ppg_align_decoded.txt
  # 2. decode the 0x47 payloads both ways:
  python decode_0x47.py captures/ppg_align_decoded.txt
"""
from __future__ import annotations

import sys
import statistics
from dataclasses import dataclass

SYNC_EPOCH = 1_577_793_600  # PROTOCOL.md §5.6
PPG_RECORD_LEN = 47
PAYLOAD_OFF = 9             # record[9:47] = 38 payload bytes (EpochRecord.PPGRecord)
MARKER = 0x0C


@dataclass
class Rec:
    counter: int            # cursor-space seconds (ring clock)
    payload: list[int]      # 38 bytes


def _bits_to_samples(payload: list[int], width: int) -> list[int]:
    """Big-endian bitstream -> consecutive `width`-bit samples (drops a partial tail)."""
    bitstr = "".join(f"{b:08b}" for b in payload)
    n = len(bitstr) // width
    return [int(bitstr[i * width:(i + 1) * width], 2) for i in range(n)]


def _extract_0x47(path: str) -> list[Rec]:
    """Pull 0x47 records out of a `decode-log` txt (lines: '... 0x0804 47 00 <cd> <recs> <xor>')."""
    out: list[Rec] = []
    with open(path) as f:
        for line in f:
            if "0x0804 47 " not in line:
                continue
            hexpart = line.split("0x0804", 1)[1].strip()
            toks = [t for t in hexpart.split() if len(t) == 2]
            try:
                body = bytes(int(t, 16) for t in toks)
            except ValueError:
                continue
            if len(body) < 4 or body[0] != 0x47:
                continue
            recs = body[3:-1]  # drop [47][00][countdown] header and the trailing xor
            for off in range(0, len(recs) - PPG_RECORD_LEN + 1, PPG_RECORD_LEN):
                r = recs[off:off + PPG_RECORD_LEN]
                if r[0] != MARKER:
                    continue
                counter = (r[0] << 24) | (r[1] << 16) | (r[2] << 8) | r[3]   # full 4-byte (incl 0x0c MSB) — matches analyze_cursor / extract_last_night
                out.append(Rec(counter=counter, payload=list(r[PAYLOAD_OFF:PPG_RECORD_LEN])))
    return out


def _smoothness(samples: list[int]) -> float:
    """mean|Δ| / std — a PULSATILE PPG is smooth (low); noise is high. A HINT, not proof."""
    if len(samples) < 3:
        return float("nan")
    sd = statistics.pstdev(samples)
    if sd == 0:
        return 0.0
    diffs = [abs(samples[i + 1] - samples[i]) for i in range(len(samples) - 1)]
    return (sum(diffs) / len(diffs)) / sd


def main() -> None:
    path = sys.argv[1] if len(sys.argv) > 1 else "captures/fresh_decoded.txt"
    recs = _extract_0x47(path)
    if not recs:
        print(f"No 0x47 records found in {path}. Generate it with `decode-log` first.")
        return

    span = (recs[-1].counter - recs[0].counter) if len(recs) > 1 else 0
    print(f"{path}: {len(recs)} × 0x47 records, counter span {span}s "
          f"(~{span/60:.1f} min of ring time)\n")

    for width, expect in ((10, 30), (12, 25)):
        allsamp: list[int] = []
        amps: list[int] = []
        per_rec_counts = set()
        for r in recs:
            s = _bits_to_samples(r.payload, width)
            per_rec_counts.add(len(s))
            allsamp += s
            if s:
                amps.append(max(s) - min(s))
        sm = _smoothness(allsamp)
        print(f"  {width}-bit BE  → {sorted(per_rec_counts)} samples/rec (expect ~{expect}); "
              f"range {min(allsamp)}–{max(allsamp)}; "
              f"median per-record p2p amplitude {statistics.median(amps):.0f}; "
              f"smoothness {sm:.2f}")
        csv = path.rsplit('.', 1)[0] + f".0x47_{width}bit.csv"
        with open(csv, "w") as out:
            out.write("ring_counter_s,sample_index,value\n")
            for r in recs:
                for i, v in enumerate(_bits_to_samples(r.payload, width)):
                    out.write(f"{r.counter},{i},{v}\n")
        print(f"             wrote {csv}")

    print("\n⚠️  Structural only. Proof = align the amplitude envelope to your finger-on/off")
    print("    timestamps + match FFT bpm to the reference HR (per issue #8). Not done here.")


if __name__ == "__main__":
    main()
