import XCTest
@testable import OpenCircuitKit

final class BatteryNotificationsTests: XCTestCase {

    private let t = BatteryNotifications.Thresholds()   // defaults: limit 80, warn 30, crit 20

    /// Thread one reading through `evaluate`, mutating `state` in place and returning what fired.
    @discardableResult
    private func step(_ percent: Int, charging: Bool,
                      _ state: inout BatteryNotifications.State,
                      thresholds: BatteryNotifications.Thresholds? = nil) -> [HealthNotification] {
        let (fire, newState) = BatteryNotifications.evaluate(
            percent: percent, charging: charging, thresholds: thresholds ?? t, state: state)
        state = newState
        return fire
    }

    // MARK: - Optimal charge limit

    func testChargeLimitFiresOnceOnCrossing() {
        var s = BatteryNotifications.State()
        XCTAssertEqual(step(79, charging: true, &s), [])              // below limit
        XCTAssertEqual(step(80, charging: true, &s), [.chargeLimitReached])
        XCTAssertEqual(step(82, charging: true, &s), [])              // already armed — silent
        XCTAssertEqual(step(85, charging: true, &s), [])
    }

    func testChargeLimitReArmsAfterUnplug() {
        var s = BatteryNotifications.State()
        XCTAssertEqual(step(80, charging: true, &s), [.chargeLimitReached])
        XCTAssertEqual(step(81, charging: false, &s), [])             // unplugged — re-arm, no fire
        XCTAssertEqual(step(85, charging: true, &s), [.chargeLimitReached]) // plugged again → fires
    }

    func testChargeLimitNotFiredWhenNotCharging() {
        var s = BatteryNotifications.State()
        XCTAssertEqual(step(95, charging: false, &s), [])
    }

    func testChargeLimitRespectsDisableFlag() {
        let off = BatteryNotifications.Thresholds(chargeLimitEnabled: false)
        var s = BatteryNotifications.State()
        XCTAssertEqual(step(90, charging: true, &s, thresholds: off), [])
    }

    func testCustomChargeLimit() {
        let custom = BatteryNotifications.Thresholds(chargeLimitPercent: 90)
        var s = BatteryNotifications.State()
        XCTAssertEqual(step(85, charging: true, &s, thresholds: custom), [])
        XCTAssertEqual(step(90, charging: true, &s, thresholds: custom), [.chargeLimitReached])
    }

    // MARK: - Low battery warning (30 %)

    func testLowWarningFiresOnceOnCrossing() {
        var s = BatteryNotifications.State()
        XCTAssertEqual(step(31, charging: false, &s), [])
        XCTAssertEqual(step(30, charging: false, &s), [.lowBatteryWarning])
        XCTAssertEqual(step(28, charging: false, &s), [])            // still low — silent
    }

    func testLowWarningReArmsAfterCharge() {
        var s = BatteryNotifications.State()
        XCTAssertEqual(step(30, charging: false, &s), [.lowBatteryWarning])
        XCTAssertEqual(step(40, charging: true, &s), [])             // charged above 30 → re-arm
        XCTAssertEqual(step(29, charging: false, &s), [.lowBatteryWarning])
    }

    // MARK: - Low battery critical (20 %)

    func testLowCriticalFires() {
        var s = BatteryNotifications.State(belowWarning: true)       // already warned earlier
        XCTAssertEqual(step(20, charging: false, &s), [.lowBatteryCritical])
        XCTAssertEqual(step(18, charging: false, &s), [])            // still critical — silent
    }

    /// A single drop straight into the critical band raises ONLY critical, never both.
    func testCriticalTakesPrecedenceOverWarning() {
        var s = BatteryNotifications.State()
        XCTAssertEqual(step(20, charging: false, &s), [.lowBatteryCritical])
        XCTAssertFalse(s.belowWarning)                               // warning was never armed/fired
    }

    // MARK: - Charging suppresses low-battery alerts

    func testNoLowAlertsWhileCharging() {
        var s = BatteryNotifications.State()
        XCTAssertEqual(step(15, charging: true, &s), [])             // charging out of a low state
        XCTAssertEqual(step(25, charging: true, &s), [])
    }

    func testLowAlertsRespectDisableFlags() {
        let off = BatteryNotifications.Thresholds(lowWarningEnabled: false, lowCriticalEnabled: false)
        var s = BatteryNotifications.State()
        XCTAssertEqual(step(30, charging: false, &s, thresholds: off), [])
        XCTAssertEqual(step(20, charging: false, &s, thresholds: off), [])
    }

    // MARK: - Full discharge sweep

    func testDischargeSweepFiresWarningThenCritical() {
        var s = BatteryNotifications.State()
        var fired: [HealthNotification] = []
        for pct in stride(from: 50, through: 15, by: -1) {
            fired += step(pct, charging: false, &s)
        }
        XCTAssertEqual(fired, [.lowBatteryWarning, .lowBatteryCritical])
    }
}