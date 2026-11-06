// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DLXControl",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "DLXControl", targets: ["DLXControl"]),
    ],
    targets: [
        .target(name: "DLXCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "DLXControl",
            dependencies: ["DLXCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DLXCoreChecks",
            dependencies: ["DLXCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
