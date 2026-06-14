// Sleep/active period detection — ported from openwhoop-algos/src/activity.rs.
// Classifies a timeline of gravity-vector readings into Sleep/Active periods by
// stillness, then `findSleep` extracts the main sleep block. Device-agnostic.
//
// ⚠️ INPUT GAP (PROTOCOL.md §5, 🔴): this needs a per-reading **gravity vector**
// (3-axis, in g). RingConn's IMU/accelerometer stream is not yet decoded — the
// 0x47/0x4c bulk frames in the reference capture are the likely source but their
// format is unconfirmed. The algorithm is ported and tested; wiring it to real
// ring data is gated on a capture. Nothing about the device is invented here.

import Foundation

/// One reading on the activity timeline. `gravity == nil` means no gravity data,
/// which the algorithm treats as movement (active), matching openwhoop.
public struct GravitySample: Sendable, Equatable {
    public let time: Date
    public let gravity: SIMD3<Float>?
    public init(time: Date, gravity: SIMD3<Float>?) {
        self.time = time
        self.gravity = gravity
    }
}

public enum Activity: Equatable, Sendable { case sleep, active }

public struct ActivityPeriod: Equatable, Sendable {
    public let activity: Activity
    public let start: Date
    public let end: Date

    public init(activity: Activity, start: Date, end: Date) {
        self.activity = activity
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var isActive: Bool { activity == .active }

    // Thresholds (from openwhoop, "notebook analysis").
    static let activityChangeThreshold: TimeInterval = 15 * 60
    static let minSleepDuration: TimeInterval = 60 * 60
    public static let maxSleepPause: TimeInterval = 60 * 60
    static let gravityStillThreshold: Float = 0.01     // g
    static let gravityWindowMinutes = 15
    static let gravityStillFraction: Float = 0.70
    static let gravityMaxGap: TimeInterval = 20 * 60

    private struct Temp { var activity: Activity; var start: Date; var end: Date }

    /// First Sleep period longer than `minSleepDuration`, removed from `events`.
    public static func findSleep(_ events: inout [ActivityPeriod]) -> ActivityPeriod? {
        while !events.isEmpty {
            let event = events.removeFirst()
            if event.activity == .sleep && event.duration > minSleepDuration { return event }
        }
        return nil
    }

    /// Detect Sleep/Active periods from a gravity-vector timeline.
    public static func detectFromGravity(_ history: [GravitySample]) -> [ActivityPeriod] {
        guard history.count >= 2 else { return [] }

        // Magnitude of change between consecutive gravity vectors (first = 0).
        // Missing gravity -> treat as max movement (active).
        var deltas: [Float] = [0]
        deltas.reserveCapacity(history.count)
        for i in 1 ..< history.count {
            if let a = history[i - 1].gravity, let b = history[i].gravity {
                let d = a - b
                deltas.append((d.x * d.x + d.y * d.y + d.z * d.z).squareRoot())
            } else {
                deltas.append(.greatestFiniteMagnitude)
            }
        }

        // Median sample interval (seconds), bounded like openwhoop.
        var diffs: [Int] = []
        for i in 1 ..< history.count {
            let d = Int(history[i].time.timeIntervalSince(history[i - 1].time))
            if d > 0 && d < 300 { diffs.append(d) }
        }
        diffs.sort()
        let avgIntervalSecs = max(1, diffs.isEmpty ? 60 : diffs[diffs.count / 2])
        let windowSize = max((gravityWindowMinutes * 60) / avgIntervalSecs, 3)

        // Rolling stillness classification (centered window).
        let n = deltas.count
        var isSleep = [Bool](repeating: false, count: n)
        let half = windowSize / 2
        for i in 0 ..< n {
            let start = i >= half ? i - half : 0
            let end = min(i + half + 1, n)
            let window = deltas[start ..< end]
            let still = window.filter { $0 < gravityStillThreshold }.count
            isSleep[i] = Float(still) / Float(window.count) >= gravityStillFraction
        }

        // Segment into runs; break on class change or a data gap > maxGap.
        var temps: [Temp] = []
        var runStart = 0
        for i in 1 ... n {
            let endOfData = (i == n)
            let classChange = !endOfData && isSleep[i] != isSleep[runStart]
            let gapBreak = !endOfData &&
                history[i].time.timeIntervalSince(history[i - 1].time) > gravityMaxGap
            if endOfData || classChange || gapBreak {
                temps.append(Temp(activity: isSleep[runStart] ? .sleep : .active,
                                  start: history[runStart].time, end: history[i - 1].time))
                if !endOfData { runStart = i }
            }
        }

        return filterMerge(temps).map {
            ActivityPeriod(activity: $0.activity, start: $0.start, end: $0.end)
        }
    }

    /// Merge sub-`activityChangeThreshold` segments into neighbors (openwhoop logic).
    private static func filterMerge(_ input: [Temp]) -> [Temp] {
        guard !input.isEmpty else { return [] }
        var activities = input
        var merged: [Temp] = []
        var i = 0
        while i < activities.count {
            let current = activities[i]
            if current.end.timeIntervalSince(current.start) < activityChangeThreshold {
                if i > 0, i + 1 < activities.count,
                   activities[i - 1].activity == activities[i + 1].activity, !merged.isEmpty {
                    let prev = merged.removeLast()
                    merged.append(Temp(activity: prev.activity, start: prev.start, end: activities[i + 1].end))
                    i += 1 // skip the next; it's merged
                } else if i + 1 < activities.count {
                    activities[i + 1] = Temp(activity: activities[i + 1].activity,
                                             start: current.start, end: activities[i + 1].end)
                } else if !merged.isEmpty {
                    let prev = merged.removeLast()
                    merged.append(Temp(activity: prev.activity, start: prev.start, end: current.end))
                }
            } else {
                merged.append(current)
            }
            i += 1
        }
        return merged
    }
}
