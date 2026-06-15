import Foundation
import CoreBluetooth
import Observation
import OpenRingKit

// Scans for the RingConn ring and connects. On iOS there are NO raw ATT handles
// (docs/HANDOFF_MACOS_IOS.md) — everything is addressed by characteristic UUID,
// so RingSession matches the notify/write characteristics by UUID after connect.
//
// The ring is matched by advertised NAME prefix ("RingConn Gen2…", 🟢). The
// notify/write characteristic UUIDs RingSession binds to are now 🟢 confirmed by
// `openringconn scan` (service 8327ad99; notify 8327ad97 = handle 0x0804; write
// 8327ad98 = handle 0x0802) — see PROTOCOL.md §1.

@Observable
@MainActor
final class RingScanner: NSObject {

    enum State: Equatable {
        case poweredOff, unauthorized, scanning, connecting(String), connected(String), idle
    }

    private(set) var state: State = .idle
    private(set) var session: RingSession?

    private var central: CBCentralManager!
    private var target: CBPeripheral?
    private var localStore: LocalStore?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// True once the user has connected; keeps us auto-reconnecting if the ring sleeps.
    private var wantConnection = false

    /// Service filter for background scans. iOS only delivers scan results to a
    /// backgrounded app when `scanForPeripherals` filters by explicit service UUIDs;
    /// a `nil` filter (used in the foreground) yields nothing in the background (#14).
    /// Caveat: this still requires the ring to advertise its data service — if it
    /// advertises name-only, background reconnection must instead use
    /// `central.connect(knownPeripheral)` against a persisted identifier.
    private static let backgroundScanServices = [CBUUID(string: OpenRingKit.Transport.dataServiceUUID)]

    /// Begin scanning. Foreground callers pass no filter: the ring is matched by its
    /// advertised name (`matchesRingName`) and is not known to advertise its data
    /// service, so filtering there could miss it. The background path passes
    /// `backgroundScanServices` because nil-filtered scans are dropped while backgrounded.
    func start(services: [CBUUID]? = nil) {
        guard central.state == .poweredOn else { return }
        wantConnection = true
        state = .scanning
        central.scanForPeripherals(withServices: services)
    }

    func stop() {
        wantConnection = false
        central.stopScan()
        if let target { central.cancelPeripheralConnection(target) }
        if case .scanning = state { state = .idle }
    }

    func setLocalStore(_ localStore: LocalStore) {
        self.localStore = localStore
        session?.setLocalStore(localStore)
    }

    /// Tear down the live link and STOP auto-reconnecting. Clearing `wantConnection`
    /// before cancelling is essential: otherwise `didDisconnectPeripheral` still wants a
    /// connection and immediately reconnects, looping forever (#14 fix).
    func disconnect() {
        wantConnection = false
        central.stopScan()
        if let target {
            central.cancelPeripheralConnection(target)
        }
        session = nil
        target = nil
        state = .idle
    }

    /// Bounded one-shot live-HR read for the background-refresh task: scan/connect,
    /// start HR monitoring, and return the first reading (or nil on timeout). Always
    /// disconnects on the way out so the link isn't held open in the background.
    func readLiveHeartRate(timeout: TimeInterval) async -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        var didStart = false
        start(services: Self.backgroundScanServices)

        defer { disconnect() }

        while !Task.isCancelled && Date() < deadline {
            if let session, session.ready {
                if !didStart {
                    session.startMonitoring(mode: .hr)
                    didStart = true
                }
                if let liveHR = session.liveHR {
                    return liveHR
                }
            } else if case .idle = state {
                start(services: Self.backgroundScanServices)
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return nil
    }
}

extension RingScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn: self.state = .idle
            case .poweredOff: self.state = .poweredOff
            case .unauthorized: self.state = .unauthorized
            default: self.state = .idle
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? ""
        guard OpenRingKit.Transport.matchesRingName(name) else { return }
        Task { @MainActor in
            self.central.stopScan()
            self.target = peripheral
            self.state = .connecting(name)
            self.central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.state = .connected(peripheral.name ?? "RingConn")
            self.session = RingSession(peripheral: peripheral, localStore: self.localStore)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.session?.stopLiveMonitoring()
            self.session = nil
            // Auto-reconnect: CoreBluetooth's connect has no timeout — it reconnects
            // (using the persisted bond) the moment the ring wakes/comes back in range,
            // so the user never has to re-pair or open the official app again.
            if self.wantConnection {
                self.state = .connecting(peripheral.name ?? "RingConn")
                self.central.connect(peripheral)
            } else {
                self.state = .idle
            }
        }
    }
}
