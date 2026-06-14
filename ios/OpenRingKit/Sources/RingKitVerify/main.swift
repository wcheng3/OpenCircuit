// CLT-friendly verification runner — mirrors OpenRingKitTests/FrameTests.swift so
// the codec can be exercised with `swift run RingKitVerify` before Xcode/XCTest is
// available. Asserts against REAL frames from the FR02.018 capture. Exits non-zero
// on any failure so it works as a loop build/test gate.

import Foundation
import OpenRingKit

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ok   \(msg)") }
    else { print("  FAIL \(msg)"); failures += 1 }
}
func hex(_ s: String) -> [UInt8] {
    var out = [UInt8](); var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!); i = j
    }
    return out
}

// Real validated notify frames from desktop/captures/btsnoop_hci.log.
let realFrames = [
    "8100b031", "82000082", "860086", "1500080ab0a7",
    "874e0400000000fd00fd00000000100c0b9e44",
    "104e0100000000fd00fd00000000100c0bffb7",
]

print("RingKitVerify — RingConn codec self-checks")

check(Frame.xorTrailer([0x95, 0x00]) == 0x95, "keepalive XOR 95 00 -> 95")
check(Frame.encode(0x95, [0x00]) == [0x95, 0x00, 0x95], "encode poll -> 95 00 95")
for f in realFrames { check(Frame.isValid(hex(f)), "real frame validates: \(f)") }

var bad = hex("8100b031"); bad[1] ^= 0xFF
check(!Frame.isValid(bad), "corrupted frame rejected")
check(!Frame.isValid([]), "empty rejected")
check(!Frame.isValid([0x81]), "single byte rejected")

let pairs: [(UInt8, UInt8)] = [
    (0x01, 0x81), (0x02, 0x82), (0x06, 0x86), (0x07, 0x87),
    (0x95, 0x15), (0xC7, 0x47), (0xCC, 0x4C), (0xD0, 0x50),
]
for (cmd, resp) in pairs {
    check(Frame.responseID(cmd) == resp, "responseID 0x\(String(cmd, radix: 16)) -> 0x\(String(resp, radix: 16))")
}

let p = Frame.parse(hex("8100b031"))
check(p == Frame.Parsed(opcode: 0x81, body: [0x00, 0xB0], trailer: 0x31), "parse splits opcode/body/trailer")
check(LiveHR.decode(hex("15005b0ab0f4")) == 91, "live HR 0x15 frame -> 91 bpm (🟡 tentative offset)")
check(LiveHR.decode([]) == nil, "empty HR -> nil")

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
