// swift-tools-version: 5.9
import PackageDescription

// OpenRingKit holds the platform-agnostic core of the iOS app: the RingConn frame
// codec (ported from desktop/openringconn/framing.py), metric models, and — later —
// the openwhoop analytics port. It depends on NO Apple frameworks so it builds and
// tests with `swift test` on the command line, without Xcode or a device. The
// CoreBluetooth / HealthKit / SwiftData glue lives in the Xcode app target and
// imports this package.
let package = Package(
    name: "OpenRingKit",
    products: [
        .library(name: "OpenRingKit", targets: ["OpenRingKit"]),
    ],
    targets: [
        .target(name: "OpenRingKit"),
        // `swift test` (needs Xcode for XCTest) runs this suite.
        .testTarget(name: "OpenRingKitTests", dependencies: ["OpenRingKit"]),
        // CLT-friendly verifier: `swift run RingKitVerify` works without Xcode,
        // asserting the same real-capture fixtures. Stopgap until Xcode is present.
        .executableTarget(name: "RingKitVerify", dependencies: ["OpenRingKit"]),
    ]
)
