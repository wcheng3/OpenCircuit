"""Drive the ring to live heart rate: init -> 02 sync -> drain history pages
(ack 47->c7, 4c->cc until remaining hits 0) -> 06 01 00 live mode -> poll 95 00 00
and decode 0x15 frames (byte[2] = HR).

    .venv/bin/python livehr.py [address]
"""
import asyncio, sys
from bleak import BleakClient
from openringconn import ble, session

ADDR = sys.argv[1] if len(sys.argv) > 1 else "63E2C4D4-7E06-CA73-568B-062FAA032213"


async def main():
    q: asyncio.Queue = asyncio.Queue()
    device = await session._resolve(ADDR, timeout=12.0)
    async with BleakClient(device) as client:
        await client.start_notify(ble.NOTIFY_CHAR, lambda _s, d: q.put_nowait(bytes(d)))

        async def w(hexstr):
            await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex(hexstr), response=True)

        # 1) init + unlock sync (0xFFFFFFFF cursor = "everything")
        for f in ("010000", "010131826700", "0200ffffffff000100"):
            await w(f); await asyncio.sleep(0.3)

        # 2) drain history: kick with 07, ack each page until remaining byte == 0
        await w("070000")
        pages = 0
        while True:
            try:
                b = await asyncio.wait_for(q.get(), timeout=3.0)
            except asyncio.TimeoutError:
                print(f"history drain: idle timeout after {pages} pages"); break
            op = b[0]
            if op == 0x47:
                pages += 1; await w("c70000")
            elif op == 0x4c:
                pages += 1; await w("cc0000")
            if op in (0x47, 0x4c) and len(b) > 2 and b[2] == 0x00:
                print(f"history drain: reached last page (remaining=0) after {pages} pages"); break

        # 3) enter live-HR mode and poll
        await w("060100"); await asyncio.sleep(0.3)
        await w("070000"); await asyncio.sleep(0.3)
        print("\n--- LIVE HR (polling 95 00 00) ---")
        hrs = []
        for _ in range(25):
            await w("950000")
            try:
                while True:
                    b = await asyncio.wait_for(q.get(), timeout=0.5)
                    if b and b[0] == 0x15 and len(b) > 2:
                        hrs.append(b[2])
                        print(f"  HR = {b[2]:>3} bpm   ({b.hex(' ')})")
            except asyncio.TimeoutError:
                pass
        await client.stop_notify(ble.NOTIFY_CHAR)
        print(f"\nlive HR samples: {hrs}")


asyncio.run(main())
