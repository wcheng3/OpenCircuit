#!/usr/bin/env python3
"""Scan a btsnoop_hci.log for BLE SMP (pairing/bonding) PDUs + encryption-change events.

Tells us whether the ring's "activation" is a fresh LE-SC bond (SMP PairingRequest at login)
vs. just re-encryption from a stored LTK (no new pairing). SMP rides L2CAP CID 0x0006.

Usage: python3 scan_smp.py captures/login_activate_20260616_btsnoop.log
"""
from __future__ import annotations
import struct, sys
from datetime import datetime, timezone, timedelta

# btsnoop microsecond epoch → unix: subtract microseconds from 0000-01-01 to 1970-01-01.
BTSNOOP_EPOCH_DELTA = 0x00dcddb30f2f8000
LOCAL = datetime.now().astimezone().tzinfo

SMP_OP = {
    0x01: "PairingRequest", 0x02: "PairingResponse", 0x03: "PairingConfirm",
    0x04: "PairingRandom", 0x05: "PairingFailed", 0x06: "EncryptionInformation(LTK)",
    0x07: "MasterIdentification", 0x08: "IdentityInformation", 0x09: "IdentityAddrInfo",
    0x0a: "SigningInformation", 0x0b: "SecurityRequest", 0x0c: "PairingPublicKey",
    0x0d: "PairingDHKeyCheck", 0x0e: "KeypressNotification",
}

def ts_local(us: int) -> str:
    unix_us = us - BTSNOOP_EPOCH_DELTA
    try:
        return datetime.fromtimestamp(unix_us / 1e6, LOCAL).strftime("%H:%M:%S")
    except Exception:
        return "??"

def main() -> None:
    path = sys.argv[1]
    with open(path, "rb") as f:
        hdr = f.read(16)
        if not hdr.startswith(b"btsnoop\x00"):
            print("not a btsnoop file"); return
        # datalink type at hdr[12:16]
        events = []
        hci_cmd_pairing = 0
        while True:
            rh = f.read(24)
            if len(rh) < 24:
                break
            orig_len, incl_len, flags, drops, ts = struct.unpack(">IIIIq", rh)
            pkt = f.read(incl_len)
            if len(pkt) < incl_len or not pkt:
                break
            # H4: first byte = type (0x01 cmd, 0x02 ACL, 0x04 event). Some snoops omit it for
            # ACL and use flags for type; handle the common H4-with-type case.
            t = pkt[0]
            body = pkt[1:]
            if t == 0x02 and len(body) >= 8:  # ACL data
                # body: handle(2) + total_len(2) + l2cap_len(2) + cid(2) + payload
                cid = struct.unpack("<H", body[6:8])[0]
                if cid == 0x0006 and len(body) >= 9:  # SMP
                    op = body[8]
                    events.append((ts, "SMP", SMP_OP.get(op, f"0x{op:02x}"), flags & 1))
            elif t == 0x04 and len(body) >= 2:  # HCI event
                evt = body[0]
                if evt == 0x08:  # Encryption Change
                    events.append((ts, "HCI", "EncryptionChange", 0))
                elif evt == 0x3e:  # LE Meta
                    sub = body[2] if len(body) > 2 else 0
                    if sub == 0x05:  # LE Long Term Key Request
                        events.append((ts, "HCI", "LE_LTK_Request", 0))

    if not events:
        print("No SMP / encryption events found."); return
    print(f"{path}: {len(events)} SMP/encryption events\n")
    pairings = [e for e in events if e[2] == "PairingRequest"]
    print(f"PairingRequests (fresh bonds): {len(pairings)}  at "
          + ", ".join(ts_local(e[0]) for e in pairings))
    encs = [e for e in events if e[2] == "EncryptionChange"]
    print(f"EncryptionChange events: {len(encs)}  "
          + ("(re-encrypt from stored LTK each reconnect)" if encs else ""))
    print(f"\nAll SMP/enc events ({'dir 1=rx' }):")
    last_t = None
    for ts, kind, name, d in events:
        gap = ""
        if last_t is not None and ts - last_t > 5_000_000:
            gap = f"   (+{(ts-last_t)/1e6:.0f}s gap)"
        print(f"  {ts_local(ts)}  {kind:4} {name:28} {'rx' if d else 'tx'}{gap}")
        last_t = ts

if __name__ == "__main__":
    main()
