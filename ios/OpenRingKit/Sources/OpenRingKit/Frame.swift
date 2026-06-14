// RingConn Gen 2 frame codec — ported from desktop/openringconn/framing.py.
//
// Ground truth is docs/PROTOCOL.md §3 (confirmed 🟢 on FW FR02.018):
//
//     [cmd][len][payload…][xor]
//
//   • cmd   — 1-byte command id (TX) / response id (RX)
//   • xor   — trailer = XOR of every byte before it
//   • len   — 2nd byte; semantics still 🟡, so this codec does NOT impose a
//             length interpretation — it only validates the XOR trailer.
//
// Do not add behavior that isn't in PROTOCOL.md. New facts go into the spec
// (and framing.py) first, then get ported here.

import Foundation

public enum Frame {

    /// XOR of every byte in `body`. The RingConn frame checksum.
    /// Mirror of `framing.xor_trailer`.
    public static func xorTrailer<S: Sequence>(_ body: S) -> UInt8 where S.Element == UInt8 {
        body.reduce(0, ^)
    }

    /// True when a whole frame's last byte is the correct XOR trailer.
    /// Mirror of `framing.frame_ok`. Verified against 86/88 real RX frames.
    public static func isValid(_ frame: [UInt8]) -> Bool {
        guard frame.count >= 2 else { return false }
        return xorTrailer(frame.dropLast()) == frame[frame.count - 1]
    }

    /// Response opcode for a command opcode: `cmd XOR 0x80`.
    /// Mirror of `framing.response_id`. Reproduced across 8 commands
    /// (01→81, 02→82, 06→86, 07→87, 95→15, c7→47, cc→4c, d0→50).
    public static let responseFlag: UInt8 = 0x80
    public static func responseID(_ cmd: UInt8) -> UInt8 { cmd ^ responseFlag }

    /// Build a command frame: `[opcode] + body + [xor]`.
    /// e.g. `encode(0x95, [0x00])` → `95 00 95` (the live poll / keepalive).
    public static func encode(_ opcode: UInt8, _ body: [UInt8] = []) -> [UInt8] {
        var frame = [opcode] + body
        frame.append(xorTrailer(frame))
        return frame
    }

    /// A parsed frame: opcode, body (bytes between opcode and trailer), trailer.
    /// Returns nil if the XOR trailer doesn't validate.
    public struct Parsed: Equatable {
        public let opcode: UInt8
        public let body: [UInt8]
        public let trailer: UInt8

        public init(opcode: UInt8, body: [UInt8], trailer: UInt8) {
            self.opcode = opcode
            self.body = body
            self.trailer = trailer
        }
    }

    public static func parse(_ frame: [UInt8]) -> Parsed? {
        guard isValid(frame) else { return nil }
        return Parsed(opcode: frame[0],
                      body: Array(frame[1..<(frame.count - 1)]),
                      trailer: frame[frame.count - 1])
    }
}
