// Sleep score — ported from openwhoop-algos/src/sleep.rs `sleep_score`.
// Device-agnostic: a function of sleep duration only. 0…100.
//
// Faithful to openwhoop, including its INTEGER-division behavior: the ratio
// duration / 8h is computed in whole units, so e.g. 4h → 0, 8h → 100, and it is
// clamped to 0…100. (This is openwhoop's current scoring; a finer model is a
// future Phase 5 refinement, flagged here rather than silently "fixed".)

import Foundation

public enum SleepScore {
    /// Ideal sleep duration in seconds (8h).
    static let idealDurationSeconds = 60 * 60 * 8

    /// Score from a sleep duration in seconds.
    public static func score(durationSeconds: Int) -> Double {
        let ratio = durationSeconds / idealDurationSeconds   // integer division, as openwhoop
        return min(max(Double(ratio) * 100.0, 0.0), 100.0)
    }

    /// Convenience for a start/end span.
    public static func score(start: Date, end: Date) -> Double {
        score(durationSeconds: Int(end.timeIntervalSince(start)))
    }
}
