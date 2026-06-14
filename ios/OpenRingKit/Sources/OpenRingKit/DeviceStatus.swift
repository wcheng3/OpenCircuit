// Device-status decode — the 0x10 / 0x87 fixed 19-byte descriptor (PROTOCOL.md §5.4).
//
// The ring emits this frame spontaneously (~30–60 s) and as the `0x07`/`0xd0` response.
// `[4:6]` is the ring's onboard **step count** (16-bit big-endian) 🟢 — confirmed by a
// from-scratch sync: the app showed 81 steps and `[4:6]` read exactly 81, `0` when idle.
// This is the ring's own count; the official app normally shows a cloud-aggregated daily
// total that can differ.

import Foundation

public enum DeviceStatus {
    /// The ring's onboard step count from a 0x10/0x87 descriptor frame, or nil if the
    /// frame isn't one. The value can legitimately be 0 (no steps yet).
    public static func steps(_ frame: [UInt8]) -> Int? {
        guard frame.count >= 19, frame[0] == 0x10 || frame[0] == 0x87 else { return nil }
        return (Int(frame[4]) << 8) | Int(frame[5])
    }
}
