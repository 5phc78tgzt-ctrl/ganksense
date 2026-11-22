// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Companion",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ganksense", targets: ["Companion"]),
        .library(name: "CompanionCore", targets: ["CompanionCore"]),
    ],
    targets: [
        .target(
            name: "CompanionCore",
            resources: [.copy("Resources/Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Companion",
            dependencies: ["CompanionCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CompanionCoreTests",
            dependencies: ["CompanionCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
