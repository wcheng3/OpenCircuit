// 7-day rolling aggregate computation for available decoded metrics (#74).
//
// SCOPE — AVAILABLE DATA ONLY.
// Daily aggregates and 7-day rolling means for the metrics we actually decode:
//   • Sleep-window HR / HRV / SpO2 / RR averages (from stored bulk-epoch samples)
//   • Steps (from StoredDaily)
//   • Nightly skin temp (from StoredSleepSummary.skinTempC)
//   • Sleep score (from StoredSleepSummary.sleepScore)
//   • Overnight stress (from StoredSleepSummary.stressScore)
//   • Resting HR (optional, from caller-supplied values)
//
// ⚠️ Daytime/waking HR, HRV, SpO2 aggregates are NOT included. They need the
// undecoded activity-epoch payload ([15:22] / #93). Those aggregates follow that
// decode — do not guess or invent daytime values.
//
// The >29 bpm HR guard is applied per the APK SQL (pp.txt:62996):
//   `AVG(CASE WHEN hrAvg>29 THEN hrAvg END) AS hr7Avg`

import Foundation

public enum TrendsEngine {

    // MARK: - Data types

    /// One day's aggregated data for trends display. All optional: nil = not available
    /// (e.g. no sleep window that night, samples pruned, metric not decoded).
    public struct DailyPoint: Equatable, Sendable {
        public let date: Date          // start-of-day (calendar day this represents)

        // Activity
        public let steps: Int?         // daily decoded step count

        // Sleep
        public let sleepMinutes: Int?  // total sleep (asleep minutes)
        public let sleepScore: Int?    // composite 0–100 (nil / 0 = not computed)
        public let stressScore: Int?   // overnight stress 0–100 (nil / 0 = not computed)
        public let skinTempC: Double?  // nightly skin temp °C (nil / 0 = no data)

        // Sleep-window vitals (from stored epoch samples within the night's window)
        // These are the ONLY HR/HRV/SpO2/RR we can aggregate — daytime values need #93.
        public let sleepHRAvg: Double?
        public let sleepHRVAvg: Double?     // ms RMSSD
        public let sleepSpO2Avg: Double?    // 0…1 fraction
        public let sleepRRAvg: Double?      // breaths/min

        public init(
            date: Date,
            steps: Int? = nil,
            sleepMinutes: Int? = nil,
            sleepScore: Int? = nil,
            stressScore: Int? = nil,
            skinTempC: Double? = nil,
            sleepHRAvg: Double? = nil,
            sleepHRVAvg: Double? = nil,
            sleepSpO2Avg: Double? = nil,
            sleepRRAvg: Double? = nil
        ) {
            self.date = date
            self.steps = steps
            self.sleepMinutes = sleepMinutes
            self.sleepScore = sleepScore
            self.stressScore = stressScore
            self.skinTempC = skinTempC
            self.sleepHRAvg = sleepHRAvg
            self.sleepHRVAvg = sleepHRVAvg
            self.sleepSpO2Avg = sleepSpO2Avg
            self.sleepRRAvg = sleepRRAvg
        }
    }

    // MARK: - 7-day rolling averages

    /// 7-day rolling averages across a window of `DailyPoint`s.
    public struct RollingAverages: Equatable, Sendable {
        public let steps: Double?
        public let sleepMinutes: Double?
        public let sleepScore: Double?
        public let stressScore: Double?
        public let skinTempC: Double?
        public let sleepHRAvg: Double?
        public let sleepHRVAvg: Double?
        public let sleepSpO2Avg: Double?
        public let sleepRRAvg: Double?
    }

    /// The APK SQL guard: exclude readings ≤ 29 bpm (pp.txt:62996).
    public static let minValidHR: Double = 29

    /// Compute 7-day (or `window`-day) rolling averages from the TRAILING points.
    /// Uses only non-nil and guard-passing values; nil when there's no valid data at all.
    public static func rollingAverages(_ points: [DailyPoint],
                                       window: Int = 7) -> RollingAverages {
        let tail = Array(points.suffix(window))
        return RollingAverages(
            steps:          avgInt(tail.compactMap(\.steps)),
            sleepMinutes:   avgInt(tail.compactMap(\.sleepMinutes)),
            sleepScore:     avgInt(tail.compactMap(\.sleepScore).filter { $0 > 0 }),
            stressScore:    avgInt(tail.compactMap(\.stressScore).filter { $0 > 0 }),
            skinTempC:      avgDouble(tail.compactMap(\.skinTempC).filter { $0 > 0 }),
            sleepHRAvg:     avgDouble(tail.compactMap(\.sleepHRAvg).filter { $0 > minValidHR }),
            sleepHRVAvg:    avgDouble(tail.compactMap(\.sleepHRVAvg).filter { $0 > 0 }),
            sleepSpO2Avg:   avgDouble(tail.compactMap(\.sleepSpO2Avg).filter { $0 > 0 }),
            sleepRRAvg:     avgDouble(tail.compactMap(\.sleepRRAvg).filter { $0 > 0 })
        )
    }

    // MARK: - Trend direction

    public enum Trend: String, Equatable, Sendable {
        case up, down, flat
    }

    /// Compare the trailing `window` days against the prior `window` days.
    /// Returns nil if there's not enough data for both windows.
    /// `minDeltaFraction` = minimum relative change to be considered non-flat.
    public static func trend(
        for points: [DailyPoint],
        window: Int = 7,
        minDeltaFraction: Double = 0.03,
        extract: (DailyPoint) -> Double?
    ) -> Trend? {
        guard points.count >= 2 else { return nil }
        let recent = Array(points.suffix(window))
        let prior  = Array(points.dropLast(recent.count).suffix(window))
        let recentVals = recent.compactMap(extract)
        let priorVals  = prior.compactMap(extract)
        guard !recentVals.isEmpty, !priorVals.isEmpty else { return nil }
        let recentMean = recentVals.reduce(0, +) / Double(recentVals.count)
        let priorMean  = priorVals.reduce(0, +) / Double(priorVals.count)
        guard abs(priorMean) > 0 else { return .flat }
        let delta = (recentMean - priorMean) / abs(priorMean)
        if delta >  minDeltaFraction { return .up }
        if delta < -minDeltaFraction { return .down }
        return .flat
    }

    // MARK: - Sleep regularity

    /// Sleep regularity score 0–100: how consistent bedtime and wake time are across
    /// the `window` nights. Based on the variance of bedtime offsets (minutes from midnight).
    /// A low-variance schedule scores near 100; a high-variance one scores near 0.
    /// nil when fewer than 2 nights have valid window data.
    public static func sleepRegularity(
        bedtimeMinutes: [Int],   // minutes since midnight for each night
        window: Int = 7
    ) -> Int? {
        let tail = Array(bedtimeMinutes.suffix(window))
        guard tail.count >= 2 else { return nil }
        let mean = Double(tail.reduce(0, +)) / Double(tail.count)
        let variance = tail.map { pow(Double($0) - mean, 2) }.reduce(0, +) / Double(tail.count)
        let stdDev = sqrt(variance)
        // Map stdDev → score: 0 min SD = 100, 60+ min SD = 0.
        let score = max(0, Int((1.0 - stdDev / 60.0) * 100.0))
        return min(score, 100)
    }

    // MARK: - Private helpers

    private static func avgDouble(_ vals: [Double]) -> Double? {
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    private static func avgInt(_ vals: [Int]) -> Double? {
        guard !vals.isEmpty else { return nil }
        return Double(vals.reduce(0, +)) / Double(vals.count)
    }
}
