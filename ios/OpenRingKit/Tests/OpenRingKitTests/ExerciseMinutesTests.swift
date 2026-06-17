import XCTest
@testable import OpenRingKit

final class ExerciseMinutesTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 0)

    // MARK: Threshold

    func testThresholdHalf() {
        // maxHR 180 → threshold = 90 bpm
        XCTAssertEqual(ExerciseMinutes.threshold(maxHR: 180), 90)
    }

    func testThresholdMinimumClamp() {
        // maxHR 60 → 50% = 30 < 60 → clamped to 60
        XCTAssertEqual(ExerciseMinutes.threshold(maxHR: 60), 60)
    }

    func testThresholdAtAge35() {
        // maxHR = 220 - 35 = 185 → 50% = 92
        XCTAssertEqual(ExerciseMinutes.threshold(maxHR: 185), 92)
    }

    // MARK: Empty / below threshold

    func testNoSamplesReturnsZero() {
        XCTAssertEqual(ExerciseMinutes.estimate(hrSamples: [], maxHR: 180), 0)
    }

    func testAllBelowThresholdReturnsZero() {
        let samples = [60, 70, 80].map { bpm in
            HRSample(bpm: bpm, start: t0, end: t0)
        }
        XCTAssertEqual(ExerciseMinutes.estimate(hrSamples: samples, maxHR: 180), 0)
    }

    // MARK: Basic elevated estimate

    func testSingleElevatedPointSampleGivesOneEpoch() {
        // One point sample at threshold → 1 epoch (150s = 2.5 min)
        let s = HRSample(bpm: 100, start: t0, end: t0)
        let minutes = ExerciseMinutes.estimate(hrSamples: [s], maxHR: 180,
                                               epochSeconds: 150)
        XCTAssertEqual(minutes, 2.5, accuracy: 0.01)
    }

    func testThreeConsecutiveEpochs() {
        // Three point samples at t=0, 150, 300 → merges to [0, 450s] = 7.5 min
        let epoch: TimeInterval = 150
        let samples = [0, 150, 300].map { offset in
            HRSample(bpm: 100, start: t0.addingTimeInterval(Double(offset)), end: t0.addingTimeInterval(Double(offset)))
        }
        let minutes = ExerciseMinutes.estimate(hrSamples: samples, maxHR: 180, epochSeconds: epoch)
        // intervals: [0,150), [150,300), [300,450) → merged: [0, 450] = 7.5 min
        XCTAssertEqual(minutes, 7.5, accuracy: 0.01)
    }

    func testGapBetweenElevatedRuns() {
        // Two isolated elevated samples with a 10-min gap → two separate intervals
        let epoch: TimeInterval = 150
        let s1 = HRSample(bpm: 100, start: t0, end: t0)
        let s2 = HRSample(bpm: 100, start: t0.addingTimeInterval(600), end: t0.addingTimeInterval(600))
        let minutes = ExerciseMinutes.estimate(hrSamples: [s1, s2], maxHR: 180, epochSeconds: epoch)
        // Two separate 150s intervals = 5 min total
        XCTAssertEqual(minutes, 5.0, accuracy: 0.01)
    }

    func testSampleWithRealDurationIsUsed() {
        // A sample spanning 5 minutes — its real duration should be used, not epochSeconds
        let end = t0.addingTimeInterval(5 * 60)
        let s = HRSample(bpm: 100, start: t0, end: end)
        let minutes = ExerciseMinutes.estimate(hrSamples: [s], maxHR: 180, epochSeconds: 150)
        XCTAssertEqual(minutes, 5.0, accuracy: 0.01)
    }

    // MARK: Sleep-window exclusion

    func testSleepWindowExcludesElevatedHR() {
        // Elevated HR samples during sleep → excluded; outside → counted
        let epoch: TimeInterval = 150
        let sleep = DateInterval(start: t0.addingTimeInterval(-3600), end: t0.addingTimeInterval(3600))
        // Inside sleep window (elevated but sleeping)
        let sleeping = HRSample(bpm: 100, start: t0, end: t0)
        // Outside sleep window (elevated and awake)
        let awake = HRSample(bpm: 100, start: t0.addingTimeInterval(7200), end: t0.addingTimeInterval(7200))

        let minutes = ExerciseMinutes.estimate(hrSamples: [sleeping, awake], maxHR: 180,
                                               sleepWindow: sleep, epochSeconds: epoch)
        // Only awake sample counted: 1 epoch = 2.5 min
        XCTAssertEqual(minutes, 2.5, accuracy: 0.01)
    }

    func testNoExclusionWhenNoSleepWindow() {
        let epoch: TimeInterval = 150
        let s = HRSample(bpm: 100, start: t0, end: t0)
        let minutes = ExerciseMinutes.estimate(hrSamples: [s], maxHR: 180,
                                               sleepWindow: nil, epochSeconds: epoch)
        XCTAssertEqual(minutes, 2.5, accuracy: 0.01)
    }

    // MARK: Interval merging

    func testOverlappingIntervalsAreMerged() {
        // Two overlapping real-duration samples → merged to one interval
        let s1 = HRSample(bpm: 100,
                          start: t0,
                          end: t0.addingTimeInterval(300))   // 5 min
        let s2 = HRSample(bpm: 110,
                          start: t0.addingTimeInterval(200), // overlaps
                          end: t0.addingTimeInterval(600))   // extends to 10 min
        let minutes = ExerciseMinutes.estimate(hrSamples: [s1, s2], maxHR: 180, epochSeconds: 150)
        // Merged: [0, 600s] = 10 min
        XCTAssertEqual(minutes, 10.0, accuracy: 0.01)
    }
}
