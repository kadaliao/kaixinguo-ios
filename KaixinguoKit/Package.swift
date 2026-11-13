// swift-tools-version:6.0
// KaixinguoKit is everything in 开心果 for iOS that is not a view: the
// catalog, playback, covers and what the app keeps on disk. It builds for
// macOS too, so `swift test` runs it on the Mac without a simulator.
import PackageDescription

let package = Package(
    name: "KaixinguoKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "KaixinguoKit", targets: ["KaixinguoKit"]),
    ],
    dependencies: [
        // 0.3.0 is the first release with the real x-argus / x-ladon
        // signatures playback needs since 2026-11-10 and the danmaku API.
        .package(url: "https://github.com/beilunyang/openhongguo.git", from: "0.3.0"),
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
