import XCTest
import OpenCircuitKit
@testable import OpenCircuit

@MainActor
final class HealthKitShareTypesTests: XCTestCase {
    /// Apple Exercise Time is an Apple-COMPUTED Activity-ring metric and is NOT third-party
    /// shareable. Listing it in HealthKit's auth `toShare` set raises an Obj-C
    /// NSInvalidArgumentException (-[HKHealthStore _throwIfAuthorizationDisallowedForSharing:])
    /// that crashed the app on first Health authorization (TestFlight #110). It must therefore
    /// have no writable quantity type, which excludes it from both the auth request and the
    /// write path. Guard against it silently creeping back in.
    func testExerciseMinutesHasNoWritableHealthKitType() {
        XCTAssertNil(HealthKitWriter.quantityType(for: .exerciseMinutes))
    }

    /// Sanity: the genuinely writable ring metrics still map to a quantity type, so the fix
    /// above didn't over-broadly drop real Health writes.
    func testWritableMetricsStillMapToAType() {
        for kind in [MetricKind.heartRate, .restingHeartRate, .hrvSDNN, .spo2, .temperature,
                     .respiratoryRate, .steps, .activeEnergy, .distance] {
            XCTAssertNotNil(HealthKitWriter.quantityType(for: kind), "\(kind) should be writable")
        }
    }
}
