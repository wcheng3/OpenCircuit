# RingConn Gen 2 — BLE Protocol (living spec)

This is the primary deliverable of Phase 1. Everything here is an **observation**,
not vendor documentation. Mark each fact with a confidence level and the capture it
came from. Treat unconfirmed entries as hypotheses to disprove.

Confidence legend: 🟢 confirmed (reproduced) · 🟡 probable · 🔴 guess / unverified

**Reference capture:** Android btsnoop, FW **FR02.018**, ring `RingConn Gen2-03AD`
(MAC `F8:79:99:F7:03:AD`), 2026-06-13 21:51. 326 ATT events: identity reads, a live
measurement (`0x95` poll loop), and a bulk history/PPG download. Pin observations
below to this FW until re-confirmed on another version.

---

## 0. Encryption gate — ANSWERED 🟢

**The BLE application layer is NOT encrypted.** ATT payloads in the capture are
plaintext: readable identity strings, monotonic counters, and a checksum that
validates (§3). No app-layer key exchange or challenge/response precedes data
access. Offline decoding is viable → the iOS app is unblocked.
(Link-layer LE encryption, if any, is transparent to CoreBluetooth — irrelevant.)

## 1. Connection & GATT layout

> ⚠️ Reported as not fully GATT-compatible. The capture confirms the app drives the
> ring almost entirely through two value handles (`0x0802` write, `0x0804` notify)
> rather than discrete per-metric characteristics.

| Item | Value | Conf. | Source |
|---|---|---|---|
| Advertised name | `RingConn Gen2-03AD` (suffix = last 2 MAC bytes) | 🟢 | capture |
| Manufacturer | `JZ_Tech` | 🟢 | capture |
| Firmware | `FR02.018` | 🟢 | capture |
| Serial | `RCA1F252311002B09` | 🟢 | capture |
| System ID / MAC | `F8:79:99:F7:03:AD` | 🟢 | capture |
| **Write / command handle** | `0x0802` | 🟢 | capture |
| **Notify handle (all responses + data)** | `0x0804` | 🟢 | capture |
| Notify CCCD (enable w/ `01 00`) | `0x0805` | 🟢 | capture |
| Notify characteristic UUID | `8327ad97-2d87-4a22-a8ce-6dd7971c0437` | 🟡 | GB #4506 |
| Write characteristic UUID | `8327ad98-2d87-4a22-a8ce-6dd7971c0437` | 🟡 | GB #4506 |
| Service A | `f7bf3564-fb6d-4e53-88a4-5e37e0326063` | 🔴 | GB #4506 |
| Service B | `984227f3-34fc-4045-a5d0-2c581f81a153` | 🔴 | GB #4506 |

> Correction to GB #4506: `0x0804` is **not** live-HR-only and `0x0802` is **not**
> keepalive-only — they are the general notify/command pair carrying every metric.
> **Action:** run `openringconn scan` to bind each handle to its UUID (iOS needs
> UUIDs, not handles) and confirm characteristic properties.

## 2. Authentication / handshake

**No app-layer handshake observed.** After enabling notifications (`0x0805 ← 01 00`)
the app immediately issues data commands and the ring responds — no token, no
challenge, no key derived from MAC/serial. History sync uses the same channel as
live data with no extra auth. (Re-verify on a *fresh pair* capture to be certain a
one-time bonding step isn't being skipped on an already-bonded phone.)

## 3. Framing 🟢

```
[cmd][len][payload…][xor]
```
- **cmd** — 1-byte command id (TX) / response id (RX).
- **Response id = command id XOR 0x80.** Reproduced across 8 commands:
  `01→81 · 02→82 · 06→86 · 07→87 · 95→15 · c7→47 · cc→4c · d0→50`.
- **xor trailer** — XOR of all preceding bytes. Validates on 86/88 RX frames and on
  the legacy `95 00 95` keepalive. (Two `0x50` status frames lack it — see §5.)
- **len** — 2nd byte; small count/sub-id. Exact semantics per command still 🟡.

Bulk history frames (`0x47`/`0x4c`) pack multiple fixed-size records, each prefixed
`0c 09 <counter>` where the counter increments ~0x0384 per record (sample index).

## 4. Commands (request → response)

| Command | Write (hex) | Resp id | Role | Conf. |
|---|---|---|---|---|
| Poll / keepalive | `95 00 00` (≡ legacy `95 00 95`) | `0x15` | live sample stream | 🟢 |
| Fetch next record | `07 00 00` | `0x87` | history record header | 🟢 |
| Page ACK / continue | `c7 00 00` / `cc 00 00` | `0x47`/`0x4c` | bulk PPG/waveform pages | 🟢 |
| Session setup | `01 00 00`, `01 01 …` | `0x81` | metadata/record table | 🟢 |
| Setup w/ 4-byte arg | `02 00 0c 22 98 c3 00 01 00` | `0x82` | arg `0c 22 98 c3` = ? (time/cursor) | 🟡 |
| Sub-select | `06 01 00` / `06 02 00` | `0x86` | selects record group | 🟡 |
| Status query | `d0 00 00` | `0x10`/`0x50` | session/record status | 🟡 |
| Set time | TBD | — | — | 🔴 |

Metric-specific sync commands (sleep/HRV/SpO2/steps/temp) not yet isolated — the
reference capture is a live HR + history-download session only.

## 5. Decoded metric formats

### Heart rate (live) 🟡
`0x95` poll → `0x15` frames. During the reading the candidate HR byte climbs
`0x52 0x54 0x58 0x5a 0x5b` (82→91) — consistent with a settling pulse measurement.
Example: `15 00 5b 0a b0 f4` (byte[2] = HR, `f4` = XOR trailer). **Confirm with a
two-reading diff** (capture two HR measurements ~10 bpm apart, diff the `0x15`
frames to lock the offset). Longer `15 01 …` frames carry additional fields
(SpO2/perfusion?), ending `… 00 60 …` (0x60 = 96).

### Bulk PPG / waveform (history) 🟡
`0x47`/`0x4c` frames, `0c 09 <ctr>`-delimited records. `0x47` records hold a
smoothly-varying ~3-byte field (raw PPG, drifts monotonically); `0x4c` records hold
a repeating `01 01 01 01 01` pattern (likely accelerometer/activity or stage marks).

### Status frames 🟡
`0x10`/`0x50` (`d0 00 00 →`), e.g. `10 4e 02 00 00 00 01 09 01 05 … 10 31 00 ff …` —
fixed-shape session/record descriptor (counts, cursor). No XOR trailer on the two
`0x50` variants; treat as a distinct frame class.

### (others)
Document each as decoded: byte offsets, scale/units, timestamp encoding
(epoch? minutes-since? local vs UTC?), and how multi-record pages are delimited.

---

## How to extend this file

1. Capture with the official app doing one thing (e.g. only a SpO2 measurement).
2. Isolate the writes/notifications in that window (`openringconn decode-log`).
3. Form a hypothesis about the command + response format; note it 🔴.
4. Replay the write with `openringconn replay` and confirm the response → 🟡.
5. Reproduce across sessions / values until stable → 🟢.
