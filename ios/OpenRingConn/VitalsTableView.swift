import SwiftUI
import SwiftData
import OpenRingKit

/// Persistent vitals dashboard. Reads the latest stored sample per metric (so values
/// are always visible offline) and prefers the live session reading when connected.
struct VitalsTableView: View {
    /// Most-recent samples first; we reduce to the latest per kind in `latest`.
    @Query(sort: \StoredSample.start, order: .reverse) private var samples: [StoredSample]
    /// Live session (optional) — its readings override stored ones while connected.
    var session: RingSession?
    /// Total sleep for the most recent night, minutes (from the last sync's segments).
    var sleepMinutes: Int?

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
            row("Respiratory Rate", value: "— (todo)", time: nil)
            divider
            row("Sleep", value: sleepText, time: nil)
        }
        .padding(.vertical, 4)
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
    private var sleepText: String {
        guard let m = sleepMinutes, m > 0 else { return "—" }
        return "\(m / 60)h \(m % 60)m"
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
