// Optimal-charging + low-battery notification policy.
//
// Three battery notifications, all PURE edge detectors (no Apple frameworks) so they unit-test on
// the CLI, mirroring `BatteryTTE.justReachedFull`. The app feeds each fresh battery reading + the
// decoded charging byte (#61) and carries an "armed" `State` across readings so each condition
// fires ONCE per crossing rather than on every frame; the app then routes survivors through the
// ONE shared `NotificationGate` (quiet hours + anti-spam backoff) like every other notification.
//
//   • chargeLimitReached — while charging, the battery reached the user's charge limit (default
//     80 %). The well-known Li-ion longevity practice: stop charging before 100 %. Configurable.
//   • lowBatteryWarning  — while NOT charging, the battery fell to the warning threshold (30 %).
//   • lowBatteryCritical — while NOT charging, the battery fell to the critical threshold (20 %).
//
// Critical and warning are mutually-exclusive bands: a reading at/under the critical threshold
// raises ONLY critical (never both), so a single drop can't double-notify.

import Foundation

public enum BatteryNotifications {

    /// User-configurable battery thresholds. Each rule has its own enable flag so a user can opt out
    /// per-rule, matching `HealthAlertThresholds`. The charge limit is configurable (default 80 %);
    /// the two low-battery thresholds default to 30 % / 20 %.
    public struct Thresholds: Equatable, Sendable {
        public var chargeLimitEnabled: Bool
        public var chargeLimitPercent: Int
        public var lowWarningEnabled: Bool
        public var lowWarningPercent: Int
        public var lowCriticalEnabled: Bool
        public var lowCriticalPercent: Int

        public init(chargeLimitEnabled: Bool = true,
                    chargeLimitPercent: Int = 80,
                    lowWarningEnabled: Bool = true,
                    lowWarningPercent: Int = 30,
                    lowCriticalEnabled: Bool = true,
                    lowCriticalPercent: Int = 20) {
            self.chargeLimitEnabled = chargeLimitEnabled
            self.chargeLimitPercent = chargeLimitPercent
            self.lowWarningEnabled = lowWarningEnabled
            self.lowWarningPercent = lowWarningPercent
            self.lowCriticalEnabled = lowCriticalEnabled
            self.lowCriticalPercent = lowCriticalPercent
        }
    }

    /// Armed state carried across battery readings so each notification fires once per crossing.
    /// A flag is set when its condition is entered and cleared once the battery leaves that band,
    /// re-arming it for the next crossing. Codable so the app may persist it if desired.
    public struct State: Equatable, Sendable, Codable {
        public var atChargeLimit: Bool
        public var belowWarning: Bool
        public var belowCritical: Bool

        public init(atChargeLimit: Bool = false,
                    belowWarning: Bool = false,
                    belowCritical: Bool = false) {
            self.atChargeLimit = atChargeLimit
            self.belowWarning = belowWarning
            self.belowCritical = belowCritical
        }
    }

    /// Evaluate one fresh battery reading. Returns the notifications that should fire NOW (before the
    /// shared DND/backoff gate) plus the updated armed `State` the caller must persist for the next
    /// reading.
    ///
    /// - `percent`:   current ring battery % (1…100).
    /// - `charging`:  the decoded on-charger signal (#61) — gates which rules can fire.
    public static func evaluate(percent: Int, charging: Bool,
                                thresholds t: Thresholds,
                                state: State) -> (fire: [HealthNotification], state: State) {
        var fire: [HealthNotification] = []
        var s = state

        // Optimal charge limit — fire once when a charging ring reaches the limit; re-arm whenever
        // it's no longer both charging AND at/above the limit (unplugged or fell back below).
        if t.chargeLimitEnabled, charging, percent >= t.chargeLimitPercent {
            if !s.atChargeLimit { fire.append(.chargeLimitReached) }
            s.atChargeLimit = true
        } else {
            s.atChargeLimit = false
        }

        // Low-battery bands (only while NOT charging). Critical takes precedence: a reading in the
        // critical band raises critical only, never the warning at the same time.
        let inCritical = percent <= t.lowCriticalPercent
        let inWarning  = percent <= t.lowWarningPercent && !inCritical

        if t.lowCriticalEnabled, !charging, inCritical {
            if !s.belowCritical { fire.append(.lowBatteryCritical) }
            s.belowCritical = true
        } else if percent > t.lowCriticalPercent {
            s.belowCritical = false      // rose back above critical — re-arm
        }

        if t.lowWarningEnabled, !charging, inWarning {
            if !s.belowWarning { fire.append(.lowBatteryWarning) }
            s.belowWarning = true
        } else if percent > t.lowWarningPercent {
            s.belowWarning = false       // rose back above warning — re-arm
        }

        return (fire, s)
    }
}