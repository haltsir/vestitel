// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Vestitel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Vestitel",
            path: "Sources/Vestitel"
        ),
        .testTarget(
            name: "VestitelTests",
            dependencies: ["Vestitel"],
            path: "Tests/VestitelTests"
        )
    ]
)
