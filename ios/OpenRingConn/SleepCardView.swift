import SwiftUI
import SwiftData
import OpenRingKit

/// Dedicated, always-visible Sleep section (its own card, sits below Vitals).
///
/// The whole point of this view is PERSISTENCE: the most recent night's sleep stays on screen
/// all day — across reconnects, foreground auto-refreshes, and manual "Sync from ring" taps —
/// until a *newer* night replaces it. Earlier, sleep was only drawn from the live session's
/// `stagedSegments` (and the sync card's just-synced batch), so a daytime sync that returned no
/// new history cleared those and the morning's sleep vanished. Here the source of truth is the
/// persisted `StoredSleepSummary` rollup (upserted by night in `LocalStore.saveSleepSummary`,
/// untouched by sample-retention pruning), so it survives offline and across launches.
///
/// A just-finished sync is still reflected instantly: `liveSegments` (this connection's freshly
/// staged night) is preferred over the store when present, mirroring the #67 rationale for the
/// vitals rows. Once the link drops, `liveSegments` is empty and the @Query store fallback
/// carries the same night forward.
///
/// Stages (Deep/Light/REM/Awake) are an on-device ESTIMATE — the ring doesn't transmit a
/// hypnogram (PROTOCOL.md §5.3) — so the card labels them "est.".
struct SleepCardView: View {
    /// Latest persisted night (capped at 1) — the offline source of truth.
    @Query private var storedSleep: [StoredSleepSummary]
    /// Freshly staged segments from the just-finished sync (empty when none / after disconnect).
    /// Preferred over the store so a completed sync updates the card immediately.
    var liveSegments: [SleepSegment]
    /// Sleep-vitals samples (HR / HRV / SpO₂) over the last few days — narrowed in memory to the
    /// resolved night window for the "overnight average" row under the stage breakdown. Bounded
    /// (value-positive + windowed) so it never scans all history (#32), mirroring
    /// `VitalsTableView.recentTemp`. A night older than this window keeps its totals but omits the
    /// averages (its raw samples have aged out of the query window).
    @Query private var recentVitals: [StoredSample]
    /// Days of HR/HRV/SpO₂ history scanned before the precise night window is applied in memory.
    private static let vitalsWindowDays: TimeInterval = 3

    init(liveSegments: [SleepSegment] = []) {
        self.liveSegments = liveSegments
        var d = FetchDescriptor<StoredSleepSummary>(sortBy: [SortDescriptor(\.night, order: .reverse)])
        d.fetchLimit = 1
        _storedSleep = Query(d)

        // Anchor the window to the start of the current hour so the descriptor stays stable across
        // rapid re-renders (re-fetching hourly or when data changes), not on every render.
        let hourStart = Calendar.current.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let lookback = hourStart.addingTimeInterval(-Self.vitalsWindowDays * 86_400)
        let hr = MetricKind.heartRate.rawValue
        let hrv = MetricKind.hrvSDNN.rawValue
        let spo2 = MetricKind.spo2.rawValue
        _recentVitals = Query(FetchDescriptor<StoredSample>(
            predicate: #Predicate {
                ($0.kindRaw == hr || $0.kindRaw == hrv || $0.kindRaw == spo2)
                    && $0.start > lookback && $0.value > 0
            },
            sortBy: [SortDescriptor(\.start, order: .reverse)]))
    }

    /// One night resolved for display, from either the live staging or the persisted rollup.
    private struct Night {
        let summary: SleepStaging.Summary
        let inBedStart: Date?
        let inBedEnd: Date?
        /// Reference time for the "last night / yesterday / date" label.
        let when: Date
        /// True when `when` is a real wake time. When false (a legacy rollup with no in-bed clock
        /// times, where `when` is only the start-of-day key) the label shows the date instead of a
        /// relative term, so a pre-midnight night isn't mislabeled "yesterday".
        let wakeKnown: Bool
    }

    /// The night to show: prefer this connection's freshly synced staging (instant), else the
    /// most recent persisted night (survives all day / offline). Only ever a real night (asleep > 0).
    /// The live `liveSegments` are already gated to overnight sleep by RingSession (review #1), so a
    /// daytime nap never reaches here as "last night".
    private var night: Night? {
        if !liveSegments.isEmpty {
            let s = SleepStaging.summary(liveSegments)
            if s.minutes.asleep > 0 {
                let start = liveSegments.map(\.start).min()
                let end = liveSegments.map(\.end).max()
                return Night(summary: s, inBedStart: start, inBedEnd: end,
                             when: end ?? start ?? Date(), wakeKnown: end != nil)
            }
        }
        if let s = storedSleep.first, s.asleepMin > 0 {
            let start = s.inBedStart > .distantPast ? s.inBedStart : nil
            let end = (s.inBedEnd > s.inBedStart) ? s.inBedEnd : nil
            return Night(summary: s.asSummary, inBedStart: start, inBedEnd: end,
                         when: end ?? start ?? s.night, wakeKnown: end != nil)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo)
                Text("SLEEP").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let night {
                    Text(Self.nightLabel(night.when, wakeKnown: night.wakeKnown))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let night {
                content(night)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(Color(.secondarySystemGroupedBackground)))
    }

    @ViewBuilder
    private func content(_ night: Night) -> some View {
        let s = night.summary
        let m = s.minutes
        // Headline: total time asleep.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(m.asleep / 60)h \(m.asleep % 60)m")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .monospacedDigit().contentTransition(.numericText())
            Text("asleep").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        }
        stageBar(m)
        stageLegend(m)
        // Overnight HR / HRV / SpO₂ averages for this night (moved out of the sync card, where
        // they read as a current "latest" reading). Computed over the night window from stored
        // samples, so they describe the same night the card is showing and persist with it.
        if let avg = overnightAverages(night) {
            overnightVitals(avg)
        }
        // Footer: sleep window · efficiency · est. caveat.
        Text(footer(night).joined(separator: " · "))
            .font(.caption2).foregroundStyle(.tertiary)
    }

    /// Mean HR (bpm) / HRV (ms) / SpO₂ (%) over the night's in-bed window, from the bounded
    /// `recentVitals` query narrowed in memory. nil when the window is unknown (a legacy rollup
    /// with no clock times) or no samples fall inside it (e.g. a night older than the query
    /// window). SpO₂ is stored 0…1 and surfaced as a whole percent.
    private func overnightAverages(_ night: Night) -> (hr: Int?, hrv: Int?, spo2: Int?)? {
        guard let start = night.inBedStart, let end = night.inBedEnd, end > start else { return nil }
        let hrKind = MetricKind.heartRate.rawValue
        let hrvKind = MetricKind.hrvSDNN.rawValue
        let spo2Kind = MetricKind.spo2.rawValue
        var hrSum = 0.0, hrN = 0, hrvSum = 0.0, hrvN = 0, spo2Sum = 0.0, spo2N = 0
        for s in recentVitals where s.start >= start && s.start <= end {
            if s.kindRaw == hrKind { hrSum += s.value; hrN += 1 }
            else if s.kindRaw == hrvKind { hrvSum += s.value; hrvN += 1 }
            else if s.kindRaw == spo2Kind { spo2Sum += s.value; spo2N += 1 }
        }
        let hr = hrN > 0 ? Int((hrSum / Double(hrN)).rounded()) : nil
        let hrv = hrvN > 0 ? Int((hrvSum / Double(hrvN)).rounded()) : nil
        let spo2 = spo2N > 0 ? Int((spo2Sum / Double(spo2N) * 100).rounded()) : nil
        return (hr == nil && hrv == nil && spo2 == nil) ? nil : (hr, hrv, spo2)
    }

    /// "Overnight average" mini-stat row (omits any metric with no samples that night).
    @ViewBuilder
    private func overnightVitals(_ avg: (hr: Int?, hrv: Int?, spo2: Int?)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Overnight average").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                if let hr = avg.hr { stat("HR", "\(hr)", "bpm") }
                if let hrv = avg.hrv { stat("HRV", "\(hrv)", "ms") }
                if let spo2 = avg.spo2 { stat("SpO₂", "\(spo2)", "%") }
            }
        }
        .padding(.top, 2)
    }

    /// Compact labeled stat for the overnight-average row.
    private func stat(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Proportional Deep/Light/REM/Awake bar, driven by the night's stage minutes.
    private func stageBar(_ m: (inBed: Int, awake: Int, light: Int, deep: Int, rem: Int, asleep: Int)) -> some View {
        let total = Double(m.deep + m.light + m.rem + m.awake)
        return GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Self.stages, id: \.name) { stage in
                    let mins = stage.minutes(m)
                    Rectangle().fill(stage.color)
                        .frame(width: total > 0 ? geo.size.width * Double(mins) / total : 0)
                }
            }
        }
        .frame(height: 12)
        .clipShape(Capsule())
    }

    /// Color key with per-stage minutes (omits stages with no time).
    private func stageLegend(_ m: (inBed: Int, awake: Int, light: Int, deep: Int, rem: Int, asleep: Int)) -> some View {
        HStack(spacing: 12) {
            ForEach(Self.stages, id: \.name) { stage in
                let mins = stage.minutes(m)
                if mins > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(stage.color).frame(width: 7, height: 7)
                        Text("\(stage.name) \(mins)m").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Footer parts: clock window (when known) + efficiency + the estimate caveat.
    private func footer(_ night: Night) -> [String] {
        var parts: [String] = []
        if let start = night.inBedStart, let end = night.inBedEnd {
            parts.append("\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))")
        }
        parts.append("\(Int((night.summary.efficiency * 100).rounded()))% efficiency")
        parts.append("est.")
        return parts
    }

    /// No-sleep state, scoped to SLEEP only. It deliberately does NOT claim HRV / Resting HR /
    /// Respiratory Rate are unavailable: those are decoded independently and can already be present
    /// (e.g. a daytime HR measurement gives a Resting HR) while no stageable sleep block exists, so
    /// asserting otherwise here would contradict the populated vitals rows above. (Review #2, #58.)
    private var emptyState: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "moon.zzz").font(.subheadline).foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your sleep appears here after an overnight sync")
                    .font(.subheadline.weight(.medium))
                Text("Wear the ring to bed and connect in the morning. Once it syncs, last night's sleep stays here all day.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Stage table

    private struct Stage {
        let name: String
        let color: Color
        let minutes: (_ m: (inBed: Int, awake: Int, light: Int, deep: Int, rem: Int, asleep: Int)) -> Int
    }
    /// Display order + colors (match the prior sync-card stage bar): Deep, Light, REM, Awake.
    private static let stages: [Stage] = [
        Stage(name: "Deep", color: .indigo, minutes: { $0.deep }),
        Stage(name: "Light", color: .teal, minutes: { $0.light }),
        Stage(name: "REM", color: .purple, minutes: { $0.rem }),
        Stage(name: "Awake", color: .orange, minutes: { $0.awake }),
    ]

    // MARK: Night label

    private static let nightDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
    /// "last night" when the sleep ended today, "yesterday" when it ended yesterday, else the date —
    /// so a days-old persisted night isn't mistaken for this morning's. Falls back to the date when
    /// the wake time is unknown (a legacy rollup with only a start-of-day key), since the relative
    /// term can't be computed reliably from the start-of-day alone. (Review #3.)
    private static func nightLabel(_ when: Date, wakeKnown: Bool) -> String {
        guard wakeKnown else { return nightDate.string(from: when) }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: when),
                                      to: cal.startOfDay(for: Date())).day ?? 0
        switch days {
        case ..<0: return nightDate.string(from: when)   // future (shouldn't happen) — show date
        case 0: return "last night"
        case 1: return "yesterday"
        default: return nightDate.string(from: when)
        }
    }
}
