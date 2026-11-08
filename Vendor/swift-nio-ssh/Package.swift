// swift-tools-version:5.10
// Vendored apple/swift-nio-ssh 0.15.1 (d1985926) with RSA host key support
// (rsa-sha2-256/512) so the phone can verify servers that only offer RSA
// host keys. See README.serverkiln.md for the patch.
import PackageDescription

let package = Package(
    name: "swift-nio-ssh",
    platforms: [.macOS(.v10_15), .iOS(.v13)],
    products: [
        .library(name: "NIOSSH", targets: ["NIOSSH"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.2"),
    ],
    targets: [
        .target(
            name: "NIOSSH",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "Atomics", package: "swift-atomics"),
            ]
        )
    ]
)
