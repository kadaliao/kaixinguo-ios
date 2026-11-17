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
        // Our fork until beilunyang/openhongguo#13 is released: v0.3.0 (the
        // x-argus / x-ladon signatures and the danmaku API) plus the V5
        // playback protocol anonymous devices need since the old video_model
        // endpoint stopped answering them in November 2026; 0.3.1-kx.2 adds
        // the tvOS slices the Apple TV app needs. Move back to upstream once
        // it ships the fix and builds for tvOS.
        .package(url: "https://github.com/kadaliao/openhongguo.git", exact: "0.3.1-kx.2"),
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
