// RingConn command/response opcodes — ported from desktop/openringconn/ble.py.
// All 🟢 confirmed from the FR02.018 capture (docs/PROTOCOL.md §4) unless noted.

import Foundation

public enum Opcode {
    /// Live-sample poll / keepalive → response 0x15. The app's `95 00 95`.
    public static let poll: UInt8 = 0x95
    /// Fetch next history record header → response 0x87.
    public static let fetchRecord: UInt8 = 0x07
    /// Bulk-transfer page ACK / continue → responses 0x47 and 0x4C.
    public static let page47: UInt8 = 0xC7
    public static let page4C: UInt8 = 0xCC

    // Session setup / metadata (roles partly 🟡 — see PROTOCOL.md §4).
    public static let sessionSetup: UInt8 = 0x01
    public static let syncOpen: UInt8 = 0x02
    public static let liveHRMode: UInt8 = 0x06
    public static let statusQuery: UInt8 = 0xD0
}

/// Exact command byte sequences, sent VERBATIM (🟢 verified live, PROTOCOL.md §3).
/// Commands are NOT XOR-checksummed — they end in a literal 0x00. Do not build
/// them with Frame.xorTrailer; that produces invalid frames the ring ignores
/// (e.g. the GB #4506 `95 00 95` is wrong — the real poll is `95 00 00`).
public enum Command {
    public static let status0: [UInt8] = [0x01, 0x00, 0x00]
    public static let status1: [UInt8] = [0x01, 0x01, 0x31, 0x82, 0x67, 0x00]
    /// Open the data session. Cursor 0xFFFFFFFF = "sync everything" (always accepted).
    public static let syncAll: [UInt8] = [0x02, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x01, 0x00]
    public static let liveHRMode: [UInt8] = [0x06, 0x01, 0x00]
    public static let fetch: [UInt8] = [0x07, 0x00, 0x00]
    public static let poll: [UInt8] = [0x95, 0x00, 0x00]
    public static let pageAck47: [UInt8] = [0xC7, 0x00, 0x00]
    public static let pageAck4C: [UInt8] = [0xCC, 0x00, 0x00]

    /// Steps to enter live-HR mode, in order (drain history between fetch/acks).
    public static let liveHRStart: [[UInt8]] = [status0, status1, syncAll, liveHRMode, fetch]
}

/// BLE transport handles (🟢). The ring is driven through this pair, not discrete
/// per-metric characteristics. iOS addresses by UUID, not handle — bind these via
/// `openringconn scan` and fill the UUIDs in PROTOCOL.md before the BLE layer.
public enum Transport {
    public static let notifyHandle: UInt16 = 0x0804   // all responses + data
    public static let writeHandle: UInt16 = 0x0802    // all commands
    public static let notifyCCCD: UInt16 = 0x0805     // enable with [0x01, 0x00]

    /// Primary data service + characteristic UUIDs (🟢 confirmed by scan, FR02.018).
    /// Value handle 0x0804 (notify) / 0x0802 (write); service handle 0x0800.
    public static let dataServiceUUID = "8327ad99-2d87-4a22-a8ce-6dd7971c0437"
    public static let notifyCharUUID = "8327ad97-2d87-4a22-a8ce-6dd7971c0437"
    public static let writeCharUUID = "8327ad98-2d87-4a22-a8ce-6dd7971c0437"

    /// Advertised-name prefixes to match while scanning. Observed name is
    /// "RingConn Gen2-<MAC suffix>" (🟢); kept broad for older variants.
    public static let namePrefixes = ["RingConn", "Ring"]

    public static func matchesRingName(_ name: String) -> Bool {
        namePrefixes.contains { name.hasPrefix($0) }
    }
}
