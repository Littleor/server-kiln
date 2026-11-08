# Security and privacy

## Basic Mac monitoring

The Mac launches `/usr/bin/ssh` using the selected target and the user's SSH
configuration. It uses batch mode and persistent sessions to run read-only
collection commands. Server identity and authentication follow OpenSSH settings;
weakening verification in your own SSH configuration also weakens this connection.

The collector reads Linux system metrics, NVIDIA GPU metrics, process commands,
working directories and elapsed times. It does not read application source files
or install a daemon during basic monitoring. It has the same access as the SSH
user, so use an account with appropriate permissions.

Preferences are stored in macOS UserDefaults. Resource history uses SQLite under
`~/Library/Application Support/ServerKiln/`; recent task metadata is also retained
locally. These records can include sensitive commands and paths. The Mac uses
existing SSH credentials rather than uploading your normal SSH private keys.

## Optional companion integration

When explicitly enabled, the official Mac build writes server lists, thresholds,
status snapshots and events to the user's private CloudKit database. That data
can include server names, endpoints, Mac names and process metadata. Apple
provides CloudKit and iCloud Keychain; this is not a project-operated relay.

Dedicated private keys are stored in synchronizable iCloud Keychain items and
are not written into CloudKit records. Monitor and terminal keys use separate
access groups. Provisioning writes tagged entries to `authorized_keys` and a
collector under `.config/serverkiln/` on the remote server:

- The monitor key uses a forced collector command and restricted forwarding.
- The optional terminal key allows a PTY and shell as the configured user.
- Host keys are pinned when the Mac verifies the deployed key. The bundled SSH
  client supports Ed25519, ECDSA and RSA SHA-2 host signatures; RSA requires at
  least 2048 bits. SHA-1 RSA signatures are not accepted by that client.

Revocation attempts to remove remote entries and delete local dedicated keys.
If the server is unreachable, remote authorization may remain: reconnect and
revoke again, or remove the corresponding tagged entries yourself. Reinstalling
or deleting the Mac app does not itself revoke remote access.

## Builds and distribution

Official downloads use Developer ID signing, hardened runtime and Apple
notarization. Ad-hoc source builds have no entitlement to the official CloudKit
container. Forks need their own identifiers, entitlements and provisioning to use
their own iCloud infrastructure; a signature cannot grant access to another
developer's container.

No analytics SDK, advertising or project-hosted telemetry endpoint is included.
Optional links open the website or App Store. Enabling Apple services subjects
those requests to your Apple account settings and Apple's policies.

Report suspected vulnerabilities using [SECURITY.md](../SECURITY.md).
