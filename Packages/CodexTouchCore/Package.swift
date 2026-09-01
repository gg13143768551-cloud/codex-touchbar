// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodexTouchCore",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "CodexTouchCore", targets: ["CodexTouchCore"])
    ],
    targets: [
        .target(name: "CodexTouchCore"),
        .testTarget(
            name: "CoreTests",
            dependencies: ["CodexTouchCore"],
            path: "Tests/CoreTests"
        ),
        .testTarget(
            name: "ContractTests",
            dependencies: ["CodexTouchCore"],
            path: "Tests/ContractTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["CodexTouchCore"],
            path: "Tests/IntegrationTests"
        )
    ]
)
