// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ControlMyMac",
    platforms: [
        // ScreenCaptureKit needs 12.3, but several SCStreamConfiguration
        // knobs we rely on landed in 14. The iOS client target is added
        // later in Xcode and links ControlMyMacKit as a local package.
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "ControlMyMacKit", targets: ["ControlMyMacKit"]),
        .executable(name: "ControlMyMacAgent", targets: ["ControlMyMacAgent"]),
        .executable(name: "ControlMyMacViewer", targets: ["ControlMyMacViewer"]),
    ],
    targets: [
        .target(name: "ControlMyMacKit"),
        .executableTarget(
            name: "ControlMyMacAgent",
            dependencies: ["ControlMyMacKit"]
        ),
        .executableTarget(
            name: "ControlMyMacViewer",
            dependencies: ["ControlMyMacKit"]
        ),
    ],
    // Deliberately Swift 5 mode: SCStreamOutput and the VideoToolbox
    // callback surfaces are pre-concurrency C/ObjC, and fighting strict
    // Sendable checking on day one buys nothing. Revisit once the
    // pipeline is stable.
    swiftLanguageModes: [.v5]
)
