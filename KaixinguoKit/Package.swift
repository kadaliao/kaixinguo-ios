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
        // Our fork only for the tvOS slices the Apple TV app needs: 0.4.1-kx.1
        // is upstream v0.4.1 (the signature the server takes since
        // 2026-11-23, and the signing-service options) with tvOS added to
        // its xcframework. Move back to beilunyang/openhongguo once
        // upstream builds for tvOS.
        .package(url: "https://github.com/kadaliao/openhongguo.git", exact: "0.4.1-kx.1"),
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
