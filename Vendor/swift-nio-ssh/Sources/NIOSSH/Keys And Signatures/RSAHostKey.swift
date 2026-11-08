import Crypto
import Foundation
import _CryptoExtras

/// An RSA host public key (verify only). Keys under 2048 bits are rejected by
/// `_RSA.Signing.PublicKey` itself.
struct RSAHostKey: Hashable, Sendable {
    let e: Data
    let n: Data
    let key: _RSA.Signing.PublicKey

    init(e: Data, n: Data) throws {
        // mpints may carry a leading zero byte for the sign bit.
        self.e = Data(e.drop(while: { $0 == 0 }))
        self.n = Data(n.drop(while: { $0 == 0 }))
        self.key = try _RSA.Signing.PublicKey(n: self.n, e: self.e)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.e == rhs.e && lhs.n == rhs.n }
    func hash(into hasher: inout Hasher) {
        hasher.combine(e)
        hasher.combine(n)
    }
}

/// An `rsa-sha2-256` / `rsa-sha2-512` signature (RFC 8332). SHA-1 `ssh-rsa`
/// signatures are deliberately unsupported.
struct RSASignatureBlob: Hashable, Sendable {
    static let algorithms = ["rsa-sha2-512", "rsa-sha2-256"]

    let algorithm: String
    let bytes: Data

    func verify(_ key: RSAHostKey, message: Data) -> Bool {
        let sig = _RSA.Signing.RSASignature(rawRepresentation: bytes)
        switch algorithm {
        case "rsa-sha2-512":
            return key.key.isValidSignature(sig, for: SHA512.hash(data: message), padding: .insecurePKCS1v1_5)
        case "rsa-sha2-256":
            return key.key.isValidSignature(sig, for: SHA256.hash(data: message), padding: .insecurePKCS1v1_5)
        default:
            return false
        }
    }

    /// For RSA, the signature algorithm must be the one negotiated (no downgrade).
    static func matches(_ signature: NIOSSHSignature, negotiated: Substring) -> Bool {
        guard case let .rsa(blob) = signature.backingSignature else { return !negotiated.hasPrefix("rsa-sha2-") }
        return blob.algorithm == negotiated
    }
}
