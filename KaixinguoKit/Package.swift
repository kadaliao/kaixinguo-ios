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
        // Our fork until beilunyang/openhongguo#7 is released: v0.2.0 plus
        // the real x-argus / x-ladon signatures playback needs since
        // 2026-11-10. Move back to upstream once it ships the fix.
        .package(url: "https://github.com/kadaliao/openhongguo.git", exact: "0.2.1-kx.1"),
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
