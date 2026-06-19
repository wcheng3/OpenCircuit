"""One-shot live-HR startup prober.

Tries several candidate startup sequences, each on a fresh connection, and reports
which (if any) produces 0x15 live-HR frames. Run once; paste the SUMMARY.

    .venv/bin/python probe_hr.py 63E2C4D4-7E06-CA73-568B-062FAA032213
"""
import asyncio, struct, sys, time
from bleak import BleakClient
from opencircuit import ble, session


def fresh_02() -> str:
    secs = int(time.time()) - 1577836800  # seconds since 2020-01-01 UTC
    return (bytes([2, 0]) + struct.pack(">I", secs) + bytes([0, 1, 0])).hex()


# Each candidate: (label, [hex frames to send after subscribe]). Then we poll 95 00 00.
def candidates():
    return [
        ("minimal_init",     ["010000", "060100", "070000"]),
        ("no_init",          ["060100", "070000"]),
        ("init_ts_no0101",   ["010000", fresh_02(), "060100", "070000"]),
        ("init_then_06only", ["010000", "060100"]),
        ("just_poll",        ["010000"]),
    ]


async def try_seq(address, label, frames):
    seen = []
    def handler(_s, data: bytearray):
        seen.append(bytes(data))
    try:
        device = await session._resolve(address, timeout=12.0)
        async with BleakClient(device) as client:
            await client.start_notify(ble.NOTIFY_CHAR, handler)
            for f in frames:
                await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex(f), response=True)
                await asyncio.sleep(0.4)
            # poll for live samples
            for _ in range(6):
                await client.write_gatt_char(ble.WRITE_CHAR, ble.KEEPALIVE_PAYLOAD, response=True)
                await asyncio.sleep(0.6)
            await client.stop_notify(ble.NOTIFY_CHAR)
    except Exception as e:
        return f"[{label}] ERROR: {e}"
    live = [s for s in seen if s and s[0] == 0x15]
    lines = [f"[{label}] sent {frames}"]
    lines.append(f"   {len(seen)} frames; {len(live)} live(0x15)")
    for s in seen:
        lines.append(f"     {s.hex(' ')}")
    if live:
        hrs = [s[2] for s in live if len(s) > 2]
        lines.append(f"   >>> LIVE HR bytes: {hrs}")
    return "\n".join(lines)


async def main(address):
    print("=== probe_hr SUMMARY ===")
    for label, frames in candidates():
        print(await try_seq(address, label, frames))
        print("-" * 40)
        await asyncio.sleep(1.5)


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else
                     "63E2C4D4-7E06-CA73-568B-062FAA032213"))
