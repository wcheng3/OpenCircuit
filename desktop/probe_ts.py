"""Probe the 02 timestamp encoding. For each candidate 4-byte value, connect
fresh, send 01 00 00 / 01 01 .../ 02<value>, and report whether an 0x82 reply
arrives (= timestamp accepted, state machine advanced). Then try 06/07 + poll.

    .venv/bin/python probe_ts.py [address]
"""
import asyncio, struct, sys, time
from bleak import BleakClient
from opencircuit import ble, session

ADDR = sys.argv[1] if len(sys.argv) > 1 else "63E2C4D4-7E06-CA73-568B-062FAA032213"
EPOCH_2020 = 1577836800


def frame02(value: int) -> bytes:
    return bytes([0x02, 0x00]) + struct.pack(">I", value & 0xFFFFFFFF) + bytes([0x00, 0x01, 0x00])


def candidates():
    now = int(time.time())
    s = now - EPOCH_2020
    return [
        ("captured_stale", 0x0c2298c3),
        ("utc_2020",       s),
        ("local_+12h",     s + 12 * 3600),   # matches capture's implied epoch
        ("local_-6h_CST",  s - 6 * 3600),
        ("local_-5h_EDT",  s - 5 * 3600),
        ("zero",           0),
        ("all_ff",         0xFFFFFFFF),
    ]


async def try_value(label, value):
    seen = []
    seq = ["010000", "010131826700", frame02(value).hex()]
    try:
        device = await session._resolve(ADDR, timeout=12.0)
        async with BleakClient(device) as client:
            await client.start_notify(ble.NOTIFY_CHAR, lambda _s, d: seen.append(bytes(d)))
            for f in seq:
                await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex(f), response=True)
                await asyncio.sleep(0.5)
            got82 = any(s and s[0] == 0x82 for s in seen)
            extra = []
            if got82:  # advanced — try to start live HR
                for f in ("060100", "070000"):
                    await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex(f), response=True)
                    await asyncio.sleep(0.4)
                for _ in range(5):
                    await client.write_gatt_char(ble.WRITE_CHAR, ble.KEEPALIVE_PAYLOAD, response=True)
                    await asyncio.sleep(0.5)
            await client.stop_notify(ble.NOTIFY_CHAR)
    except Exception as e:
        return f"[{label:14}] value=0x{value:08x} ERROR: {e}"
    got82 = any(s and s[0] == 0x82 for s in seen)
    live = [s for s in seen if s and s[0] == 0x15]
    tag = "  <<< 02 ACCEPTED (0x82)!" if got82 else ""
    if live:
        tag += f"  LIVE-HR bytes={[s[2] for s in live if len(s)>2]} !!!"
    return f"[{label:14}] value=0x{value:08x}  frames={[s.hex() for s in seen]}{tag}"


async def main():
    print("=== probe_ts SUMMARY ===")
    for label, value in candidates():
        print(await try_value(label, value))
        await asyncio.sleep(1.2)


asyncio.run(main())
