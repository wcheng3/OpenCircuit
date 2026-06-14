import XCTest
@testable import OpenRingKit

// Fixtures are REAL frames pulled from the FR02.018 reference capture
// (desktop/captures/btsnoop_hci.log) — not hand-authored. They mirror the
// self-checks in framing.py so the Swift port is provably byte-identical.
final class FrameTests: XCTestCase {

    func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    // Real validated notify frames (opcode → full hex) from the capture.
    let realFrames = [
        "8100b031", "82000082", "860086", "1500080ab0a7",
        "874e0400000000fd00fd00000000100c0b9e44",
        "104e0100000000fd00fd00000000100c0bffb7",
    ]

    func testXorTrailerMatchesKeepalive() {
        // The app's live poll / keepalive: 95 00 95.
        XCTAssertEqual(Frame.xorTrailer([0x95, 0x00]), 0x95)
        XCTAssertEqual(Frame.encode(0x95, [0x00]), [0x95, 0x00, 0x95])
    }

    func testRealFramesValidate() {
        for f in realFrames {
            XCTAssertTrue(Frame.isValid(hex(f)), "should validate: \(f)")
        }
    }

    func testCorruptedFrameRejected() {
        var bad = hex("8100b031"); bad[1] ^= 0xFF
        XCTAssertFalse(Frame.isValid(bad))
        XCTAssertNil(Frame.parse(bad))
        XCTAssertFalse(Frame.isValid([]))
        XCTAssertFalse(Frame.isValid([0x81]))
    }

    func testResponseIDRule() {
        // response = command XOR 0x80, across all 8 confirmed commands.
        let pairs: [(UInt8, UInt8)] = [
            (0x01, 0x81), (0x02, 0x82), (0x06, 0x86), (0x07, 0x87),
            (0x95, 0x15), (0xC7, 0x47), (0xCC, 0x4C), (0xD0, 0x50),
        ]
        for (cmd, resp) in pairs {
            XCTAssertEqual(Frame.responseID(cmd), resp)
            XCTAssertEqual(Frame.responseID(resp), cmd) // involutive
        }
    }

    func testParseSplitsOpcodeBodyTrailer() {
        let p = Frame.parse(hex("8100b031"))
        XCTAssertEqual(p, Frame.Parsed(opcode: 0x81, body: [0x00, 0xB0], trailer: 0x31))
    }

    func testEncodeRoundTrips() {
        for opcode: UInt8 in [0x01, 0x07, 0x95, 0xCC] {
            let frame = Frame.encode(opcode, [0x00, 0x00])
            XCTAssertTrue(Frame.isValid(frame))
            XCTAssertEqual(Frame.parse(frame)?.opcode, opcode)
        }
    }

    func testLiveHRDecode() {
        // Real 0x15 frame from the capture: byte[2] = 0x5B = 91 bpm.
        XCTAssertEqual(LiveHR.decode(hex("15005b0ab0f4")), 91)
        XCTAssertNil(LiveHR.decode([]))
    }
}
