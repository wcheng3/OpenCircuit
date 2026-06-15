import Foundation
import OpenRingKit

@MainActor
struct RingBackgroundSyncService {
    private let store: LocalStore
    private let health: HealthKitWriter

    init(store: LocalStore, health: HealthKitWriter) {
        self.store = store
        self.health = health
    }

    func syncLiveHeartRate(timeout: TimeInterval = 20) async throws -> Bool {
        let scanner = RingScanner()
        guard let hr = await scanner.readLiveHeartRate(timeout: timeout) else {
            return false
        }

        let now = Date()
        let samples = try store.ingest([
            QuantitySample(kind: .heartRate, start: now, value: Double(hr))
        ])
        if HealthKitWriter.isAvailable {
            try? await health.write(samples)
        }
        return true
    }
}
