// swift-tools-version: 6.0
// Platform-independent core of the iPhone app: packet format, group encryption, and forwarding.
// Same behavior and bytes as the Android app's Core.kt; see spec/FORMAT.md.
import PackageDescription

let package = Package(
    name: "BlackoutCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "BlackoutCore", targets: ["BlackoutCore"])],
    targets: [
        .target(name: "BlackoutCore"),
        .testTarget(name: "BlackoutCoreTests", dependencies: ["BlackoutCore"]),
    ]
)
