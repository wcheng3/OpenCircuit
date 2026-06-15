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

    /// One bounded background read so the app already has last night's data on open. The
    /// drain inside `captureForBackground` persists overnight HR/HRV/SpO2 + sleep + steps +
    /// skin temp to the local store (the dashboard's source); here we then mirror everything
    /// pending into Apple Health, each metric watermark-gated so nothing double-writes.
    /// Returns the BGTask success flag — true when we captured ANY data, not only a live HR,
    /// so iOS keeps scheduling us even on nights the optical HR never locks.
    @discardableResult
    func syncVitals(timeout: TimeInterval = 20) async throws -> Bool {
        let scanner = RingScanner.shared
        scanner.setLocalStore(store)   // RingSession auto-persists the drained history + temp
        let capture = await scanner.captureForBackground(timeout: timeout)

        var mirrored = false
        if HealthKitWriter.isAvailable {
            mirrored = await health.flushToHealth(store: store,
                                                  sleepSegments: capture.sleepSegments).wroteAnything
        }
        // Success = we captured fresh data OR mirrored previously-pending data to Health, so a
        // run that only flushed a backlog still counts (iOS uses this to keep scheduling us).
        return capture.gotData || mirrored
    }
}
