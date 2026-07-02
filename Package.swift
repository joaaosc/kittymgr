// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kittymgr",
    platforms: [.macOS(.v13)],
    dependencies: [
        // SHA-256 for the snapshot store, source cache, and kitten checksums.
        // On Apple platforms CryptoKit is used directly (see the `#if canImport`
        // guards) and this product is not linked; it is only compiled on Linux.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.0"),
    ],
    targets: [
        .target(
            name: "KittymgrCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ],
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
