# Third-party notices

ServerKiln's original code is available under the [MIT license](LICENSE).
Dependencies retain their own licenses. Copies are included in
`Resources/Licenses` and bundled with the app.

| Component | Version | License | Source |
| --- | --- | --- | --- |
| Sparkle | 2.10.1 | MIT | [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle) |
| SwiftNIO SSH (modified) | 0.15.1 | Apache-2.0 | [apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh) |
| SwiftNIO | 2.104.0 | Apache-2.0 | [apple/swift-nio](https://github.com/apple/swift-nio) |
| Swift Crypto | 4.5.2 | Apache-2.0 | [apple/swift-crypto](https://github.com/apple/swift-crypto) |
| Swift ASN.1 | 1.7.4 | Apache-2.0 | [apple/swift-asn1](https://github.com/apple/swift-asn1) |
| Swift Atomics | 1.3.1 | Apache-2.0 | [apple/swift-atomics](https://github.com/apple/swift-atomics) |
| Swift Collections | 1.7.5 | Apache-2.0 | [apple/swift-collections](https://github.com/apple/swift-collections) |
| Swift System | 1.8.1 | Apache-2.0 | [apple/swift-system](https://github.com/apple/swift-system) |

The complete versions and revisions are pinned in `Package.resolved`.
SwiftNIO includes llhttp under its MIT license. Swift Crypto includes BoringSSL
and other components whose notices are retained with its distribution.
The locally modified SSH implementation and its provenance are described in
[the vendor notes](Vendor/swift-nio-ssh/README.serverkiln.md).

macOS frameworks, the system OpenSSH client and SQLite are supplied by the
operating system and are not redistributed here.
