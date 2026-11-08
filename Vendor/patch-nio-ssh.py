#!/usr/bin/env python3
"""Adds RSA *host key* verification (rsa-sha2-512 / rsa-sha2-256) to a pristine
apple/swift-nio-ssh checkout. Client side only: we never sign with RSA and
never accept SHA-1 `ssh-rsa` signatures or keys under 2048 bits.

Usage: Vendor/patch-nio-ssh.py Vendor/swift-nio-ssh
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1]) / "Sources/NIOSSH"
KS = root / "Keys And Signatures"


def patch(path, pairs):
    s = path.read_text()
    for old, new in pairs:
        if old not in s:
            sys.exit(f"patch anchor not found in {path.name}:\n{old[:200]}")
        s = s.replace(old, new, 1)
    path.write_text(s)


# MARK: public key ------------------------------------------------------------
patch(KS / "NIOSSHPublicKey.swift", [
    ("import NIOCore\n", "import NIOCore\nimport _CryptoExtras\n"),
    # Digest verification (exchange hash): RSA verifies over the raw hash bytes
    # with the hash chosen by the signature algorithm.
    ("""        case (.certified(let key), _):
            return key.isValidSignature(signature, for: digest)
        case (.ed25519, _),
            (.ecdsaP256, _),
            (.ecdsaP384, _),
            (.ecdsaP521, _):
            return false
        }
    }
""", """        case (.rsa(let key), .rsa(let sig)):
            return digest.withUnsafeBytes { sig.verify(key, message: Data($0)) }
        case (.certified(let key), _):
            return key.isValidSignature(signature, for: digest)
        case (.ed25519, _),
            (.ecdsaP256, _),
            (.ecdsaP384, _),
            (.ecdsaP521, _),
            (.rsa, _):
            return false
        }
    }
"""),
    ("""        case (.certified(let key), _):
            return key.isValidSignature(signature, for: bytes)
        case (.ed25519, _),
            (.ecdsaP256, _),
            (.ecdsaP384, _),
            (.ecdsaP521, _):
            return false""", """        case (.rsa(let key), .rsa(let sig)):
            return sig.verify(key, message: Data(bytes.readableBytesView))
        case (.certified(let key), _):
            return key.isValidSignature(signature, for: bytes)
        case (.ed25519, _),
            (.ecdsaP256, _),
            (.ecdsaP384, _),
            (.ecdsaP521, _),
            (.rsa, _):
            return false"""),
    ("""        case (.certified(let key), _):
            return key.isValidSignature(signature, for: payload)
        case (.ed25519, _),
            (.ecdsaP256, _),
            (.ecdsaP384, _),
            (.ecdsaP521, _):
            return false""", """        case (.rsa(let key), .rsa(let sig)):
            return sig.verify(key, message: Data(payload.bytes.readableBytesView))
        case (.certified(let key), _):
            return key.isValidSignature(signature, for: payload)
        case (.ed25519, _),
            (.ecdsaP256, _),
            (.ecdsaP384, _),
            (.ecdsaP521, _),
            (.rsa, _):
            return false"""),
    ("""        case ecdsaP521(P521.Signing.PublicKey)
        case certified""", """        case ecdsaP521(P521.Signing.PublicKey)
        case rsa(RSAHostKey)
        case certified"""),
    ("""    internal static let ecdsaP521PublicKeyPrefix = "ecdsa-sha2-nistp521".utf8
""", """    internal static let ecdsaP521PublicKeyPrefix = "ecdsa-sha2-nistp521".utf8

    /// The key blob type of an RSA public key (signatures use rsa-sha2-*).
    internal static let rsaPublicKeyPrefix = "ssh-rsa".utf8
"""),
    ("""        case .ecdsaP521:
            return Self.ecdsaP521PublicKeyPrefix
        case .certified(let base):
            return base.keyPrefix""", """        case .ecdsaP521:
            return Self.ecdsaP521PublicKeyPrefix
        case .rsa:
            return Self.rsaPublicKeyPrefix
        case .certified(let base):
            return base.keyPrefix"""),
    ("""        case (.certified(let lhs), .certified(let rhs)):
            return lhs == rhs
        case (.ed25519, _),
            (.ecdsaP256, _),
            (.ecdsaP384, _),
            (.ecdsaP521, _),
            (.certified, _):""", """        case (.rsa(let lhs), .rsa(let rhs)):
            return lhs == rhs
        case (.certified(let lhs), .certified(let rhs)):
            return lhs == rhs
        case (.ed25519, _),
            (.ecdsaP256, _),
            (.ecdsaP384, _),
            (.ecdsaP521, _),
            (.rsa, _),
            (.certified, _):"""),
    ("""        case .certified(let pkey):
            hasher.combine(5)
            hasher.combine(pkey)""", """        case .rsa(let pkey):
            hasher.combine(6)
            hasher.combine(pkey)
        case .certified(let pkey):
            hasher.combine(5)
            hasher.combine(pkey)"""),
    ("""        case .ecdsaP521(let key):
            writtenBytes += self.writeSSHString(NIOSSHPublicKey.ecdsaP521PublicKeyPrefix)
            writtenBytes += self.writeECDSAP521PublicKey(baseKey: key)
        case .certified""", """        case .ecdsaP521(let key):
            writtenBytes += self.writeSSHString(NIOSSHPublicKey.ecdsaP521PublicKeyPrefix)
            writtenBytes += self.writeECDSAP521PublicKey(baseKey: key)
        case .rsa(let key):
            writtenBytes += self.writeSSHString(NIOSSHPublicKey.rsaPublicKeyPrefix)
            writtenBytes += self.writePositiveMPInt(key.e)
            writtenBytes += self.writePositiveMPInt(key.n)
        case .certified"""),
    ("""        case .ecdsaP521(let key):
            return self.writeECDSAP521PublicKey(baseKey: key)
        case .certified:
            preconditionFailure""", """        case .ecdsaP521(let key):
            return self.writeECDSAP521PublicKey(baseKey: key)
        case .rsa(let key):
            return self.writePositiveMPInt(key.e) + self.writePositiveMPInt(key.n)
        case .certified:
            preconditionFailure"""),
    ("""            } else if keyIdentifierBytes.elementsEqual(NIOSSHPublicKey.ecdsaP521PublicKeyPrefix) {
                return try buffer.readECDSAP521PublicKey()
            } else {""", """            } else if keyIdentifierBytes.elementsEqual(NIOSSHPublicKey.ecdsaP521PublicKeyPrefix) {
                return try buffer.readECDSAP521PublicKey()
            } else if keyIdentifierBytes.elementsEqual(NIOSSHPublicKey.rsaPublicKeyPrefix) {
                // RFC 4253 §6.6: mpint e, mpint n.
                guard let e = buffer.readSSHString(), let n = buffer.readSSHString() else { return nil }
                return try NIOSSHPublicKey(backingKey: .rsa(RSAHostKey(e: Data(e.readableBytesView), n: Data(n.readableBytesView))))
            } else {"""),
])

# MARK: signature ---------------------------------------------------------------
patch(KS / "NIOSSHSignature.swift", [
    ("import NIOFoundationCompat\n", "import NIOFoundationCompat\nimport _CryptoExtras\n"),
    ("""        case ecdsaP521(P521.Signing.ECDSASignature)
""", """        case ecdsaP521(P521.Signing.ECDSASignature)

        /// Verify-only: servers sign the exchange hash, clients never sign with RSA here.
        case rsa(RSASignatureBlob)
"""),
    ("""        case (.ecdsaP521(let lhs), .ecdsaP521(let rhs)):
            return lhs.rawRepresentation == rhs.rawRepresentation
        case (.ed25519, _),
            (.ecdsaP256, _),
            (.ecdsaP384, _),
            (.ecdsaP521, _):
            return false""", """        case (.ecdsaP521(let lhs), .ecdsaP521(let rhs)):
            return lhs.rawRepresentation == rhs.rawRepresentation
        case (.rsa(let lhs), .rsa(let rhs)):
            return lhs == rhs
        case (.ed25519, _),
            (.ecdsaP256, _),
            (.ecdsaP384, _),
            (.ecdsaP521, _),
            (.rsa, _):
            return false"""),
    ("""        case .ecdsaP521(let sig):
            hasher.combine(3)
            hasher.combine(sig.rawRepresentation)
        }""", """        case .ecdsaP521(let sig):
            hasher.combine(3)
            hasher.combine(sig.rawRepresentation)
        case .rsa(let sig):
            hasher.combine(4)
            hasher.combine(sig)
        }"""),
    ("""        case .ecdsaP521(let sig):
            return self.writeECDSAP521Signature(baseSignature: sig)
        }""", """        case .ecdsaP521(let sig):
            return self.writeECDSAP521Signature(baseSignature: sig)
        case .rsa(let sig):
            return self.writeSSHString(sig.algorithm.utf8) + self.writeSSHString(sig.bytes)
        }"""),
    ("""            } else if bytesView.elementsEqual(NIOSSHSignature.ecdsaP521SignaturePrefix) {
                return try buffer.readECDSAP521Signature()
            } else {""", """            } else if bytesView.elementsEqual(NIOSSHSignature.ecdsaP521SignaturePrefix) {
                return try buffer.readECDSAP521Signature()
            } else if let algorithm = RSASignatureBlob.algorithms.first(where: { bytesView.elementsEqual($0.utf8) }) {
                guard let sig = buffer.readSSHString() else { return nil }
                return NIOSSHSignature(backingSignature: .rsa(RSASignatureBlob(algorithm: algorithm, bytes: Data(sig.readableBytesView))))
            } else {"""),
])

# Private keys never hold RSA, but exhaustive switches over the public backing key do.
patch(KS / "NIOSSHCertifiedPublicKey.swift", [
    ("""        case .ecdsaP521:
            return Self.p521KeyPrefix
        case .certified:""", """        case .ecdsaP521:
            return Self.p521KeyPrefix
        case .rsa:
            preconditionFailure("RSA certificates are not supported")
        case .certified:"""),
])

# MARK: negotiation ---------------------------------------------------------------
# Offer rsa-sha2-* last, so Ed25519/ECDSA still win whenever the server has them.
# The negotiated name differs from the key blob type ("ssh-rsa"), so the
# host-key-type check maps it back.
patch(root / "Key Exchange/SSHKeyExchangeStateMachine.swift", [
    ("""        "ssh-ed25519", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp521",
    ]""", """        "ssh-ed25519", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp521",
        "rsa-sha2-512", "rsa-sha2-256",
    ]"""),
    ("""                guard message.hostKey.keyPrefix.elementsEqual(negotiated.negotiatedHostKeyAlgorithm.utf8) else {""",
     """                let expectedKeyType = negotiated.negotiatedHostKeyAlgorithm.hasPrefix("rsa-sha2-")
                    ? "ssh-rsa" : negotiated.negotiatedHostKeyAlgorithm
                guard message.hostKey.keyPrefix.elementsEqual(expectedKeyType.utf8),
                    RSASignatureBlob.matches(message.signature, negotiated: negotiated.negotiatedHostKeyAlgorithm)
                else {"""),
])

(KS / "RSAHostKey.swift").write_text('''import Crypto
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
''')
print("patched")
