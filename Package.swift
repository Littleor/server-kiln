// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ServerKiln",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ServerKiln", targets: ["ServerKiln"]),
        .library(name: "ServerKilnCore", targets: ["ServerKilnCore"]),
        .library(name: "ServerKilnSSH", targets: ["ServerKilnSSH"]),
        .library(name: "ServerKilnSync", targets: ["ServerKilnSync"]),
        .library(name: "ServerKilnUI", targets: ["ServerKilnUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
        // Vendored with RSA host key support, see Vendor/patch-nio-ssh.py.
        .package(path: "Vendor/swift-nio-ssh"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-crypto", "3.0.0" ..< "5.0.0"),
    ],
    targets: [
        .target(name: "ServerKilnCore"),
        /// SSH client used to verify dedicated keys before the Mac publishes them.
        .target(
            name: "ServerKilnSSH",
            dependencies: [
                "ServerKilnCore",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        /// iCloud keychain, CloudKit records and dedicated key deployment.
        .target(
            name: "ServerKilnSync",
            dependencies: [
                "ServerKilnCore",
                "ServerKilnSSH",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        /// Reusable SwiftUI building blocks for the Mac interface.
        .target(name: "ServerKilnUI", dependencies: ["ServerKilnCore"]),
        .executableTarget(
            name: "ServerKiln",
            dependencies: ["ServerKilnCore", "ServerKilnSSH", "ServerKilnSync", "ServerKilnUI", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(
            name: "ServerKilnCoreTests",
            dependencies: [
                "ServerKilnCore", "ServerKilnSSH", "ServerKilnSync",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
    ]
)
