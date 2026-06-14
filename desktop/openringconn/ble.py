"""Known RingConn Gen 2 BLE constants.

Everything here is OBSERVED. Items tagged 🟢 are reproduced from a real btsnoop
capture (FW FR02.018, see docs/PROTOCOL.md); 🟡/🔴 still need confirming. Update
this file and docs/PROTOCOL.md together.

Sources: capture FR02.018 (2026-06-13); Gadgetbridge issue #4506.
"""

# Characteristics (🟡 — UUIDs from GB #4506; bind to the handles below via `scan`).
NOTIFY_CHAR = "8327ad97-2d87-4a22-a8ce-6dd7971c0437"
WRITE_CHAR = "8327ad98-2d87-4a22-a8ce-6dd7971c0437"

# Services seen in scans (🔴 unverified roles)
SERVICE_A = "f7bf3564-fb6d-4e53-88a4-5e37e0326063"
SERVICE_B = "984227f3-34fc-4045-a5d0-2c581f81a153"

# ATT handles (🟢 confirmed from capture). The app drives the ring almost entirely
# through this notify/command pair, NOT discrete per-metric characteristics.
HANDLE_NOTIFY = 0x0804         # all responses + live + bulk data arrive here
HANDLE_WRITE = 0x0802          # all commands are written here
HANDLE_NOTIFY_CCCD = 0x0805    # enable notifications with `01 00`

# Back-compat aliases for the earlier (mis-scoped) GB #4506 names.
HANDLE_LIVE_HR_NOTIFY = HANDLE_NOTIFY
HANDLE_KEEPALIVE_WRITE = HANDLE_WRITE

# Frame opcodes (🟢). Response id = command id XOR RESP_FLAG.
RESP_FLAG = 0x80
CMD_POLL = 0x95          # live-sample poll/keepalive  -> 0x15
CMD_FETCH_RECORD = 0x07  # next history record header  -> 0x87
CMD_PAGE_47 = 0xC7       # page ACK / continue bulk    -> 0x47
CMD_PAGE_4C = 0xCC       # page ACK / continue bulk    -> 0x4C

# The live poll/keepalive the official app writes (🟢). `95 00 95` and `95 00 00`
# are the same command + XOR trailer (see framing.xor_trailer).
KEEPALIVE_PAYLOAD = bytes.fromhex("950095")

# Name prefixes to match while scanning (🟢 — observed "RingConn Gen2-<MAC suffix>").
NAME_PREFIXES = ("RingConn", "Ring")
