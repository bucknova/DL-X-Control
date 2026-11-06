// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DL24Control",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "DL24Control", targets: ["DL24Control"]),
    ],
    targets: [
        .target(name: "DL24Core", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "DL24Control",
            dependencies: ["DL24Core"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DL24CoreChecks",
            dependencies: ["DL24Core"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
