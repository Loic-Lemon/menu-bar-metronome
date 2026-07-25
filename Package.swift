// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Metronome",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Metronome",
            path: "Sources/Metronome",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .interoperabilityMode(.C)
            ]
        )
    ]
)
