// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lights",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "LightsCore",
            path: "Sources/LightsCore"
        ),
        .executableTarget(
            name: "Lights",
            dependencies: ["LightsCore"],
            path: "Sources/Lights"
        ),
        // Plain executable so the checks run with Command Line Tools alone (no XCTest needed).
        .executableTarget(
            name: "lights-selftest",
            dependencies: ["LightsCore"],
            path: "Sources/LightsSelfTest"
        ),
    ]
)
