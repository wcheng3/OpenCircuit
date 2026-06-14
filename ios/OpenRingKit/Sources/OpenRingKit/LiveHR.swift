// Live heart-rate decode — ported from desktop/openringconn/framing.py.
//
// ⚠️ 🟡 PROBABLE, not confirmed (docs/PROTOCOL.md §5). In `0x95`-poll responses
// shaped `15 00 <hr> 0a b0 <xor>`, byte[2] tracks a settling pulse (82→91 bpm
// across one reading). The exact offset still needs a two-reading diff capture
// to lock down. Until then, callers should treat the result as tentative.

import Foundation

public enum LiveHR {
    /// Best-known decode of a live-HR sample (0x15 frame on the notify handle).
    /// Returns nil for empty input. Mirrors `framing.decode_live_hr`.
    public static func decode(_ payload: [UInt8]) -> Int? {
        guard let last = payload.last else { return nil }
        if payload.count >= 4 && payload[0] == 0x15 {
            return Int(payload[2])
        }
        // Legacy fallback (older GB #4506 guess: low 7 bits of last byte).
        return Int(last & 0x7F)
    }
}
