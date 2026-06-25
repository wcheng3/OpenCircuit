import XCTest
@testable import OpenCircuitKit

// Parity with openwhoop-algos/src/activity.rs unit tests.
final class SleepDetectionTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    func reading(_ minutes: Int, _ g: SIMD3<Float>?) -> GravitySample {
        GravitySample(time: base.addingTimeInterval(Double(minutes) * 60), gravity: g)
    }

    func testEmptyAndSingle() {
        XCTAssertTrue(ActivityPeriod.detectFromGravity([]).isEmpty)
        XCTAssertTrue(ActivityPeriod.detectFromGravity([reading(0, SIMD3(0, 0, 1))]).isEmpty)
    }

    func testAllStillIsSleep() {
        let h = (0..<120).map { reading($0, SIMD3(0, 0, 1)) }
        let p = ActivityPeriod.detectFromGravity(h)
        XCTAssertFalse(p.isEmpty)
        XCTAssertEqual(p.first?.activity, .sleep)
    }

    func testAllMovingIsActive() {
        let h = (0..<120).map { reading($0, SIMD3($0 % 2 == 0 ? 1 : -1, 0, 0)) }
        XCTAssertEqual(ActivityPeriod.detectFromGravity(h).first?.activity, .active)
    }

    func testNoGravityIsActive() {
        let h = (0..<120).map { reading($0, nil) }
        XCTAssertEqual(ActivityPeriod.detectFromGravity(h).first?.activity, .active)
    }

    func testGapBreaksRun() {
        var h = (0..<60).map { reading($0, SIMD3(0, 0, 1)) }
        h += (120..<180).map { reading($0, SIMD3(0, 0, 1)) }
        XCTAssertGreaterThanOrEqual(ActivityPeriod.detectFromGravity(h).count, 2)
    }

    func testFindSleepReturnsLong() {
        var events = [
            ActivityPeriod(activity: .active, start: base, end: base.addingTimeInterval(30 * 60)),
            ActivityPeriod(activity: .sleep, start: base.addingTimeInterval(30 * 60), end: base.addingTimeInterval(300 * 60)),
        ]
        XCTAssertEqual(ActivityPeriod.findSleep(&events)?.activity, .sleep)
    }

    func testFindSleepIgnoresShort() {
        var events = [ActivityPeriod(activity: .sleep, start: base, end: base.addingTimeInterval(30 * 60))]
        XCTAssertNil(ActivityPeriod.findSleep(&events))
    }

    func testFindSleepEmpty() {
        var events: [ActivityPeriod] = []
        XCTAssertNil(ActivityPeriod.findSleep(&events))
    }

    func testIsActive() {
        XCTAssertTrue(ActivityPeriod(activity: .active, start: base, end: base.addingTimeInterval(3600)).isActive)
        XCTAssertFalse(ActivityPeriod(activity: .sleep, start: base, end: base.addingTimeInterval(3600)).isActive)
    }

    // MARK: #41 — wear / charging gate

    /// A 4 h still motion block (would detect as sleep) sampled every 5 min.
    private func stillNight() -> [MotionSample] {
        (0..<48).map { MotionSample(time: base.addingTimeInterval(Double($0) * 5 * 60), movement: 1) }
    }
    private func temps(_ celsius: Double) -> [TemperatureSample] {
        (0..<48).map { TemperatureSample(time: base.addingTimeInterval(Double($0) * 5 * 60), celsius: celsius) }
    }

    func testWearGateReclassifiesColdStillBlockAsActive() {
        let motion = stillNight()
        XCTAssertEqual(ActivityPeriod.detectFromMotion(motion).first?.activity, .sleep,
                       "motion-only: a still block reads as sleep")
        // Same motion, but skin temp ~22 °C (off-wrist / charging) -> no sleep survives.
        let gated = ActivityPeriod.detectFromMotion(motion, temperatureSamples: temps(22))
        XCTAssertFalse(gated.contains { $0.activity == .sleep },
                       "cold (unworn) still block must not count as sleep")
    }

    func testWearGateKeepsWarmStillBlockAsSleep() {
        let gated = ActivityPeriod.detectFromMotion(stillNight(), temperatureSamples: temps(32))
        XCTAssertEqual(gated.first?.activity, .sleep, "worn (32 °C) still block stays sleep")
    }

    func testWearGateNoTemperatureLeavesDetectionUnchanged() {
        let motion = stillNight()
        XCTAssertEqual(ActivityPeriod.detectFromMotion(motion, temperatureSamples: []),
                       ActivityPeriod.detectFromMotion(motion),
                       "no temperature coverage -> identical to motion-only (absence ≠ unworn)")
    }

    // MARK: HR gate — awake-but-still rejection (the "sleep while I was out" bug, 2026-06-23)

    /// Still motion across `[startMin, endMin)` at 5-min cadence (reads as sleep, motion-only).
    private func stillMotion(_ startMin: Int, _ endMin: Int) -> [MotionSample] {
        stride(from: startMin, to: endMin, by: 5).map {
            MotionSample(time: base.addingTimeInterval(Double($0) * 60), movement: 1)
        }
    }
    private func hrSeries(_ startMin: Int, _ endMin: Int, bpm: Int) -> [HeartRateSample] {
        stride(from: startMin, to: endMin, by: 5).map {
            HeartRateSample(time: base.addingTimeInterval(Double($0) * 60), bpm: bpm)
        }
    }
    /// Is `minute` inside a detected `.sleep` period?
    private func sleepCovers(_ minute: Int, _ periods: [ActivityPeriod]) -> Bool {
        let t = base.addingTimeInterval(Double(minute) * 60)
        return periods.contains { $0.activity == .sleep && $0.start <= t && $0.end >= t }
    }

    /// The reported failure: a still-but-AWAKE evening (sitting out late, HR ~108) staged as sleep,
    /// then real low-HR sleep after a buffer gap. Motion-only stages the evening; the HR gate removes
    /// it and keeps the real block. Models the 2026-06-23 night: evening "sleep" 97–120 bpm, then the
    /// 00:09→06:29 HR hole (the overnight drain gap), then real sleep ~64 bpm — floor ~64.
    func testHeartRateGateRejectsAwakeStillEveningBlock() {
        // 60-min data gap (120→180) > gravityMaxGap → detect() breaks the run, so the two still
        // blocks are separate periods (no fragile reliance on the motion floor splitting them).
        let motion = stillMotion(0, 120) + stillMotion(180, 480)
        let hr = hrSeries(0, 120, bpm: 108) + hrSeries(180, 480, bpm: 64)

        let motionOnly = ActivityPeriod.detectFromMotion(motion, temperatureSamples: [])
        XCTAssertTrue(sleepCovers(60, motionOnly), "motion-only stages the still evening as sleep")

        let gated = ActivityPeriod.detectFromMotion(motion, temperatureSamples: [], heartRateSamples: hr)
        XCTAssertFalse(sleepCovers(60, gated), "awake-but-still evening (HR 108 ≫ floor) must not be sleep")
        XCTAssertTrue(sleepCovers(300, gated), "real low-HR (64 bpm) sleep block survives the gate")
    }

    /// No regression: a genuinely still, low-HR night stays sleep (median near the floor).
    func testHeartRateGateKeepsRealLowHRSleep() {
        let gated = ActivityPeriod.detectFromMotion(stillMotion(0, 300), temperatureSamples: [],
                                                    heartRateSamples: hrSeries(0, 300, bpm: 60))
        XCTAssertEqual(gated.first?.activity, .sleep, "uniformly low-HR still night stays sleep")
    }

    /// No HR coverage → identical to motion-only (absence of HR is not evidence of wakefulness).
    func testHeartRateGateNoHRLeavesDetectionUnchanged() {
        let motion = stillMotion(0, 300)
        XCTAssertEqual(ActivityPeriod.detectFromMotion(motion, temperatureSamples: [], heartRateSamples: []),
                       ActivityPeriod.detectFromMotion(motion),
                       "no HR coverage → identical to motion-only")
    }

    /// Too few HR readings → the gate stays out rather than acting on noise.
    func testHeartRateGateIgnoresSparseHR() {
        let motion = stillMotion(0, 300)
        let hr = [HeartRateSample(time: base, bpm: 120),
                  HeartRateSample(time: base.addingTimeInterval(60 * 60), bpm: 120)]   // < minHRSamplesForGate
        XCTAssertEqual(ActivityPeriod.detectFromMotion(motion, temperatureSamples: [], heartRateSamples: hr).first?.activity,
                       .sleep, "too few HR readings → gate stays out, block remains sleep")
    }
}
