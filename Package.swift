// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexWindowKicker",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CodexWindowKickerCore", targets: ["CodexWindowKickerCore"]),
        .executable(name: "CodexWindowKicker", targets: ["CodexWindowKickerApp"]),
    ],
    targets: [
        .target(name: "CodexWindowKickerCore"),
        .executableTarget(
            name: "CodexWindowKickerApp",
            dependencies: ["CodexWindowKickerCore"]
        ),
        .testTarget(
            name: "CodexWindowKickerCoreTests",
            dependencies: ["CodexWindowKickerCore"]
        ),
    ]
)
