import SwiftUI
import SwiftData
import OpenRingKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var scanner = RingScanner()
    @State private var healthAuthorized = false
    @State private var lastWrite: String?

    private let health = HealthKitWriter()

    var body: some View {
        NavigationStack {
            List {
                Section("Ring") {
                    LabeledContent("Status", value: statusText)
                    if let hr = scanner.session?.liveHR {
                        LabeledContent("Live HR", value: "\(hr) bpm")
                    }
                    if let frame = scanner.session?.lastFrame {
                        LabeledContent("Last frame", value: frame)
                            .font(.caption.monospaced())
                    }
                }

                Section("Actions") {
                    Button("Scan & connect") { scanner.start() }
                    Button("Start live HR") { scanner.session?.startLiveHR() }
                        .disabled(scanner.session?.ready != true)
                    Button("Poll live HR") { scanner.session?.pollLiveHR() }
                        .disabled(scanner.session?.ready != true)
                    Button(healthAuthorized ? "Health authorized" : "Authorize Apple Health") {
                        Task {
                            try? await health.requestAuthorization()
                            healthAuthorized = true
                        }
                    }
                    .disabled(!HealthKitWriter.isAvailable)
                }

                Section("Sleep & history") {
                    Button(scanner.session?.syncing == true ? "Syncing…" : "Sync history") {
                        scanner.session?.syncHistory()
                    }
                    .disabled(scanner.session?.ready != true || scanner.session?.syncing == true)

                    if let samples = scanner.session?.historySamples, !samples.isEmpty {
                        LabeledContent("Decoded samples", value: "\(samples.count)")
                    }
                    if let segs = scanner.session?.sleepSegments, !segs.isEmpty,
                       let inBed = segs.first(where: { $0.stage == .inBed }) {
                        LabeledContent("Sleep window",
                                       value: "\(inBed.start.formatted(date: .omitted, time: .shortened))–\(inBed.end.formatted(date: .omitted, time: .shortened))")
                    }
                    if let staged = scanner.session?.stagedSegments, !staged.isEmpty {
                        LabeledContent("Stages (experimental)", value: stageSummary(staged))
                            .font(.caption)
                    }
                    if let samples = scanner.session?.historySamples, !samples.isEmpty {
                        Button("Write to Apple Health") { writeToHealth(samples) }
                            .disabled(!healthAuthorized)
                    }
                    if let lastWrite { LabeledContent("Last write", value: lastWrite) }
                }
            }
            .navigationTitle("OpenRingConn")
        }
    }

    /// Persist + dedup via LocalStore (cursor-based), then write only the NEW
    /// samples/segments to HealthKit — so re-syncs backfill without duplicating.
    private func writeToHealth(_ samples: [QuantitySample]) {
        let store = LocalStore(modelContext)
        let segments = scanner.session?.sleepSegments ?? []
        Task {
            do {
                let freshSamples = try store.ingest(samples)
                try await health.write(freshSamples)
                let freshSleep = try store.ingestSleep(segments)
                if !freshSleep.isEmpty { try await health.write(sleep: freshSleep) }
                lastWrite = "\(freshSamples.count) new samples, \(freshSleep.count) sleep segs"
            } catch {
                lastWrite = "error: \(error.localizedDescription)"
            }
        }
    }

    /// "D 90m · R 115m · L 242m · W 13m" from staged segments (excludes inBed).
    private func stageSummary(_ segs: [SleepSegment]) -> String {
        func mins(_ stage: SleepStage) -> Int {
            Int(segs.filter { $0.stage == stage }.reduce(0) { $0 + $1.duration } / 60)
        }
        return "D \(mins(.asleepDeep))m · R \(mins(.asleepREM))m · L \(mins(.asleepCore))m · W \(mins(.awake))m"
    }

    private var statusText: String {
        switch scanner.state {
        case .idle: return "Idle"
        case .poweredOff: return "Bluetooth off"
        case .unauthorized: return "Bluetooth unauthorized"
        case .scanning: return "Scanning…"
        case .connecting(let n): return "Connecting to \(n)…"
        case .connected(let n): return "Connected: \(n)"
        }
    }
}
