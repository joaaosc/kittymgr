// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kittymgr",
    targets: [
        .target(
            name: "KittymgrCore",
            path: "src"
        ),
        .executableTarget(
            name: "kittymgr",
            dependencies: ["KittymgrCore"],
            path: "Sources/kittymgr"
        ),
        .testTarget(
            name: "KittymgrCoreTests",
            dependencies: ["KittymgrCore"],
            path: "Tests/KittymgrCoreTests"
        ),
    ]
)
