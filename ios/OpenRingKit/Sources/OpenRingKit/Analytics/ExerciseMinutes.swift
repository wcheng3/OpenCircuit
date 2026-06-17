// Estimate Apple Exercise Time (elevated-HR minutes) from stored HR samples (#82).
//
// SCOPE — BASIC ESTIMATE ONLY.
// A basic threshold model: minutes where HR ≥ 50% of max HR (equivalent to brisk
// walking, Apple's own exercise definition). This estimate uses ONLY the decoded
// HR samples we have — sleep-window bulk epochs (0x4c[4], 🟢) and live monitoring
// readings — and EXCLUDES the overnight sleep window to avoid counting sleeping
// elevated HR as voluntary exercise.
//
// ⚠️ The FULL 4-level intensity mapping (Vigorous/Moderate/Low/Inactive minutes)
// is GATED on the activity-epoch decode (#93). That payload at 0x4c[15:22] carries
// the true per-epoch activity intensity; do NOT invent 4 intensity buckets from
// the basic HR threshold alone. This file is the basic-threshold placeholder only.
//
// HealthKit target: `.appleExerciseTime` (written by HealthKitWriter as a delta,
// not stored as a ring sample in LocalStore).

import Foundation

public enum ExerciseMinutes {

    /// HR threshold for exercise: ≥ 50% of max HR (brisk-walking equivalent).
    /// NOTE: Full 4-level intensity (Vigorous/Moderate/Low/Inactive) follows #93 decode.
    public static func threshold(maxHR: Int) -> Int {
        return max(Int(Double(max(maxHR, 1)) * 0.5), 60)
    }

    /// Estimate exercise minutes as the total merged duration of elevated-HR intervals,
    /// excluding samples that fall inside a sleep window.
    ///
    /// Algorithm:
    /// 1. Filter to samples with HR ≥ threshold and outside the sleep window.
    /// 2. Map each sample to an interval [start, max(end, start+epochSeconds)] — point
    ///    samples (start==end) get a one-epoch width so a single elevated bulk record
    ///    contributes its full epoch instead of 0 seconds.
    /// 3. Merge overlapping intervals so consecutive elevated epochs are counted once.
    /// 4. Return the sum of merged interval durations in minutes.
    ///
    /// ESTIMATE — based on available HR samples only. Accuracy improves after #93 decode.
    public static func estimate(
        hrSamples: [HRSample],
        maxHR: Int,
        sleepWindow: DateInterval? = nil,
        epochSeconds: TimeInterval = TimeInterval(BulkRecord.epochSeconds)
    ) -> Double {
        let thresh = threshold(maxHR: maxHR)
        let elevated = hrSamples
            .filter { s in
                s.bpm >= thresh
                    && (sleepWindow.map { !$0.contains(s.start) } ?? true)
            }
            .sorted { $0.start < $1.start }

        guard !elevated.isEmpty else { return 0 }

        // Build intervals: point samples get one epoch width.
        let intervals: [(Date, Date)] = elevated.map { s in
            let dur = s.end.timeIntervalSince(s.start)
            let end = dur > 0 ? s.end : s.start.addingTimeInterval(epochSeconds)
            return (s.start, end)
        }

        // Merge overlapping / adjacent intervals.
        var merged: [(Date, Date)] = [intervals[0]]
        for (start, end) in intervals.dropFirst() {
            if start <= merged[merged.count - 1].1 {
                let last = merged[merged.count - 1]
                merged[merged.count - 1] = (last.0, max(end, last.1))
            } else {
                merged.append((start, end))
            }
        }

        let totalSeconds = merged.reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) }
        return totalSeconds / 60.0
    }
}
