# ServerKiln's SwiftNIO SSH patch

Based on [apple/swift-nio-ssh 0.15.1](https://github.com/apple/swift-nio-ssh/tree/0.15.1),
commit `d1985926494b624e751b379009dc83f3395fd88a`, under Apache-2.0.
Upstream copyright and license headers are preserved.

The Mac verifies the dedicated keys it deploys using this client. Some hosts
offer only RSA host keys. The local patch adds verification of RSA host keys
using `rsa-sha2-256` and `rsa-sha2-512`, requires at least 2048-bit RSA keys,
and rejects a signature algorithm that differs from the negotiated algorithm.
It does not add RSA client authentication or accept SHA-1 `ssh-rsa` signatures.

Modifications are in the public-key, signature, key-exchange and RSA host-key
implementations. `Vendor/patch-nio-ssh.py` records the source changes and is
applied to a **pristine** upstream source tree, not to this already-patched copy.
The package manifest is also reduced to the library target and adds the
`_CryptoExtras` dependency. It is maintained separately from the patch script.

`LocalSSHDTests` and `LocalSSHDRSATests` exercise real local SSH handshakes,
host-key rejection, forced monitor commands and terminal access. Run them with
`swift test --filter LocalSSHD` from the repository root. Tests may skip on hosts
that cannot start an unprivileged `sshd`; inspect the test output.

When updating upstream, reapply and review the patch, retain upstream notices,
update dependency notices, and run the full suite. Do not replace this directory
with an unreviewed upstream version: RSA-only server compatibility depends on it.
