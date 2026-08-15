// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgenticCLIKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AgenticCLIKit", targets: ["AgenticCLIKit"]),
        .library(name: "AgenticCLIKitTesting", targets: ["AgenticCLIKitTesting"]),
        .executable(name: "agentickit", targets: ["agentickit"]),
    ],
    targets: [
        .target(
            name: "AgenticCLIKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AgenticCLIKitTesting",
            dependencies: ["AgenticCLIKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "agentickit",
            dependencies: ["AgenticCLIKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AgenticCLIKitTests",
            dependencies: ["AgenticCLIKit", "AgenticCLIKitTesting"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
