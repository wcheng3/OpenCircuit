// Live heart-rate decode — ported from desktop/openringconn/framing.py.
//
// 🟢 CONFIRMED (docs/PROTOCOL.md §5). A `0x95`-poll response is shaped
// `15 00 <hr> 0a b0 <xor>`; **byte[2] = HR in bpm**. Verified by a targeted
// HR-only capture that settled to a stable 61 bpm resting pulse. The first sample
// after entering live mode is a warm-up sentinel (byte[2] ≈ 8) before the PPG locks.

import Foundation

public enum LiveHR {
    /// Below this, the sensor hasn't locked on (warm-up); treat as not-yet-valid.
    public static let minValidBPM = 30

    /// HR in bpm from a 0x15 live frame, or nil if not a valid live frame.
    public static func decode(_ payload: [UInt8]) -> Int? {
        guard payload.count >= 4, payload[0] == 0x15 else { return nil }
        return Int(payload[2])
    }

    /// HR only once the sensor has locked on (filters the warm-up sentinel).
    public static func decodeLocked(_ payload: [UInt8]) -> Int? {
        guard let hr = decode(payload), hr >= minValidBPM else { return nil }
        return hr
    }
}
