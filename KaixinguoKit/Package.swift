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
        // Our fork until upstream releases 0.3.0: upstream's main as of
        // 2769fb6, with the real x-argus / x-ladon signatures playback needs
        // since 2026-11-10 (beilunyang/openhongguo#7) and the danmaku API.
        // Move back to upstream once 0.3.0 ships.
        .package(url: "https://github.com/kadaliao/openhongguo.git", exact: "0.3.0-kx.1"),
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
