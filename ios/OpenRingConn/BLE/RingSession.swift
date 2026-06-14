import Foundation
import CoreBluetooth
import Observation
import OpenRingKit

// An active link to a connected ring: discovers the notify/write characteristics
// by UUID, enables notifications, sends commands, and decodes responses through
// OpenRingKit's confirmed codec. Only spec-supported behavior is implemented:
//   • live-HR poll (0x95 → 0x15, LiveHR.decode 🟡)
// History/metric sync commands exist in the codec, but their RESPONSE record
// formats are 🔴 (PROTOCOL.md §5) — decoding them is deliberately left as a
// flagged TODO pending a capture, rather than invented here.

@Observable
@MainActor
final class RingSession: NSObject {

    private(set) var liveHR: Int?
    private(set) var lastFrame: String?
    private(set) var ready = false

    private let peripheral: CBPeripheral
    private var notifyChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?

    private let notifyUUID = CBUUID(string: OpenRingKit.Transport.notifyCharUUID)
    private let writeUUID = CBUUID(string: OpenRingKit.Transport.writeCharUUID)

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    /// Enter live-HR mode: status → open sync (cursor=all) → live mode → fetch.
    /// History backlog (47/4c pages) is drained by acking in didUpdateValue.
    func startLiveHR() {
        for cmd in Command.liveHRStart { write(cmd) }
    }

    /// Poll for one live sample (0x95 → 0x15). Sent verbatim — NOT XOR-encoded.
    func pollLiveHR() {
        write(Command.poll)
    }

    private func write(_ bytes: [UInt8]) {
        guard let writeChar else { return }
        // Write char advertises `write` (with response).
        peripheral.writeValue(Data(bytes), for: writeChar, type: .withResponse)
    }
}

extension RingSession: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            for ch in service.characteristics ?? [] {
                if ch.uuid == self.notifyUUID {
                    self.notifyChar = ch
                    peripheral.setNotifyValue(true, for: ch)
                } else if ch.uuid == self.writeUUID {
                    self.writeChar = ch
                }
            }
            self.ready = (self.notifyChar != nil && self.writeChar != nil)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        Task { @MainActor in
            self.lastFrame = data.map { String(format: "%02x", $0) }.joined(separator: " ")
            // Bulk history pages: ack to continue draining (47→c7, 4c→cc).
            switch bytes.first {
            case 0x47: self.write(Command.pageAck47); return
            case 0x4C: self.write(Command.pageAck4C); return
            default: break
            }
            guard let frame = Frame.parse(bytes) else { return }   // XOR-validate responses
            // 0x15 is the live-sample stream (resp of 0x95 poll).
            if frame.opcode == Frame.responseID(Opcode.poll) {
                self.liveHR = LiveHR.decode(bytes)   // 🟡 offset tentative
            }
        }
    }
}
