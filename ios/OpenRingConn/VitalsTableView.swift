import SwiftUI
import SwiftData
import OpenRingKit

/// Persistent vitals dashboard. Reads the latest stored sample per metric (so values
/// are always visible offline) and prefers the live session reading when connected.
struct VitalsTableView: View {
    /// Most-recent samples first; we reduce to the latest per kind in `latest`.
    @Query(sort: \StoredSample.start, order: .reverse) private var samples: [StoredSample]
    /// Persisted sleep summaries (latest night first) — the offline fallback for `sleep`.
    @Query(sort: \StoredSleepSummary.night, order: .reverse) private var storedSleep: [StoredSleepSummary]
    /// Persisted daily rollups (latest day first) — the offline fallback for live steps.
    @Query(sort: \StoredDaily.day, order: .reverse) private var storedDaily: [StoredDaily]
    /// Live session (optional) — its readings override stored ones while connected.
    var session: RingSession?
    /// LIVE sleep summary for the most recent night (total asleep + estimated stage
    /// breakdown). When nil (no live session), `effectiveSleep` falls back to the store.
    var sleep: SleepStaging.Summary?

    /// Prefer the live session summary; fall back to the latest stored night offline.
    private var effectiveSleep: SleepStaging.Summary? {
        if let sleep { return sleep }
        guard let s = storedSleep.first, s.asleepMin > 0 else { return nil }
        return s.asSummary
    }

    /// Prefer the ring's live onboard count; fall back to today's stored count offline.
    private var effectiveSteps: Int? {
        session?.steps ?? storedDaily.first?.steps
    }

    private var latest: [MetricKind: StoredSample] {
        var out: [MetricKind: StoredSample] = [:]
        for s in samples {
            guard let k = MetricKind(rawValue: s.kindRaw), out[k] == nil else { continue }
            out[k] = s
        }
        return out
    }

    /// Resting HR ≈ the lowest HR over the last 24 h (sleep low), derived from stored HR.
    private var restingHR: Int? {
        let dayAgo = Date().addingTimeInterval(-86_400)
        let hrs = samples
            .filter { $0.kindRaw == MetricKind.heartRate.rawValue && $0.start > dayAgo && $0.value > 0 }
            .map { $0.value }
        return hrs.min().map { Int($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Heart Rate", value: hrText, time: timeFor(.heartRate, live: session?.liveHR != nil))
            divider
            row("SpO₂", value: spo2Text, time: timeFor(.spo2, live: session?.liveSpO2 != nil))
            divider
            row("Skin Temp", value: tempText, time: timeFor(.temperature, live: session?.liveTemperature != nil))
            divider
            row("HRV", value: valueText(.hrvSDNN) { "\(Int($0)) ms" }, time: timeFor(.hrvSDNN))
            divider
            row("Resting HR", value: restingHR.map { "\($0) bpm" } ?? "—", time: nil)
            divider
            row("Steps (today)", value: stepsText, time: stepsTime)
            divider
            row("Respiratory Rate", value: "— (todo)", time: nil)
            divider
            sleepSection
        }
        .padding(.vertical, 4)
    }

    /// Sleep: total asleep + estimated Deep/Light/REM/Awake breakdown (stages are an
    /// on-device estimate — the ring doesn't send stage labels).
    @ViewBuilder private var sleepSection: some View {
        if let s = effectiveSleep, s.minutes.asleep > 0 {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Sleep").font(.subheadline)
                    Spacer()
                    Text("\(s.minutes.asleep / 60)h \(s.minutes.asleep % 60)m")
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                Text("Deep \(s.minutes.deep)m · Light \(s.minutes.light)m · REM \(s.minutes.rem)m · Awake \(s.minutes.awake)m")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("est. · \(Int((s.efficiency * 100).rounded()))% efficiency")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
        } else {
            row("Sleep", value: "—", time: nil)
        }
    }

    // MARK: rows

    private func row(_ label: String, value: String, time: String?) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.primary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                if let time { Text(time).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 8)
    }

    private var divider: some View { Divider().opacity(0.4) }

    // MARK: value formatting (live overrides stored)

    private var hrText: String {
        if let hr = session?.liveHR { return "\(hr) bpm" }
        return valueText(.heartRate) { "\(Int($0)) bpm" }
    }
    private var spo2Text: String {
        if let s = session?.liveSpO2 { return "\(s) %" }
        return valueText(.spo2) { "\(Int(($0 * 100).rounded())) %" }
    }
    private var tempText: String {
        if let c = session?.liveTemperature { return tempString(c) }
        return valueText(.temperature) { tempString($0) }
    }
    /// Ring's onboard step count — live while connected (the descriptor streams it). It's
    /// the ring's own count, which can differ from the official app's cloud daily total.
    private var stepsText: String {
        guard let s = effectiveSteps else { return "—" }
        return "\(s)"
    }
    /// "live" while connected; else the relative time of the stored day's last update.
    private var stepsTime: String? {
        if session?.steps != nil { return "live" }
        guard let d = storedDaily.first, d.steps > 0 else { return nil }
        return Self.rel.localizedString(for: d.updatedAt, relativeTo: Date())
    }

    private func tempString(_ celsius: Double) -> String {
        String(format: "%.1f °C  (%.1f °F)", celsius, celsius * 9 / 5 + 32)
    }

    /// Latest stored value for `kind`, formatted, or "—" if none.
    private func valueText(_ kind: MetricKind, _ fmt: (Double) -> String) -> String {
        latest[kind].map { fmt($0.value) } ?? "—"
    }

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()
    private func timeFor(_ kind: MetricKind, live: Bool = false) -> String? {
        if live { return "live" }
        guard let s = latest[kind] else { return nil }
        return Self.rel.localizedString(for: s.start, relativeTo: Date())
    }
}
