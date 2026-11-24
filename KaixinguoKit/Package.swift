// swift-tools-version:6.0
// KaixinguoKit is everything in 开心果 for iOS and tvOS that is not a view:
// the catalog, playback, covers and what the app keeps on disk. It builds
// for macOS too, so `swift test` runs it on the Mac without a simulator.
import PackageDescription

let package = Package(
    name: "KaixinguoKit",
    platforms: [.iOS(.v18), .tvOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "KaixinguoKit", targets: ["KaixinguoKit"]),
    ],
    dependencies: [
        // Our fork: 0.4.1-kx.3 is upstream v0.4.1 with tvOS added to its
        // xcframework (for the Apple TV app) and upstream's unmerged #16,
        // which reads playback from video_tab when the playback endpoints
        // come back empty for anonymous devices (since 2026-11-24). Move back
        // to beilunyang/openhongguo once upstream ships both.
        .package(url: "https://github.com/kadaliao/openhongguo.git", exact: "0.4.1-kx.3"),
    ],
    targets: [
        .target(name: "CENC"),
        .target(
            name: "KaixinguoKit",
            dependencies: ["CENC", .product(name: "Openhongguo", package: "openhongguo")]
        ),
        .testTarget(name: "CENCTests", dependencies: ["CENC"]),
        .testTarget(name: "KaixinguoKitTests", dependencies: ["KaixinguoKit"]),
    ]
)
