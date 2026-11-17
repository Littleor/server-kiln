# Security and privacy

## Windows monitoring and optional iPhone notifications

The Windows client uses native OpenSSH with strict host-key checking, batch mode,
agent forwarding disabled and one persistent process per server. It inherits
credentials, jumps and proxy commands from the selected user's SSH configuration;
no private key import into the application is required. Arguments bypass a local
shell. Unknown host fingerprints and encrypted keys must first be handled in
an interactive terminal using the same OpenSSH client and agent.

The first-connection action and monitoring resolve the same effective OpenSSH
configuration. Valid custom host-key stores are inherited, including multiple
files and host CA entries. Discard-only stores such as `UserKnownHostsFile /dev/null`
fall back to `%LOCALAPPDATA%\ServerKiln\known_hosts` plus the standard Windows
OpenSSH `~/.ssh/known_hosts`.
Interactive setup asks the user to verify an unknown fingerprint; background
monitoring requires a trusted key. Changed host keys are never removed or
accepted automatically. A per-server private-key override stores only the file
path and uses `-i` / `IdentitiesOnly=yes` in both connection modes.

Preferences, SQLite history and recent job metadata are stored under
`%LOCALAPPDATA%\ServerKiln`. Process commands and working directories can be
sensitive. An optional Bark key is stored separately with Windows DPAPI for the
current account; it is not included in the JSON preferences or history database.

Bark is opt-in. The configured HTTPS relay receives the device key, server
display name and a short activity notification. SSH keys, process commands and
working directories are not included. HTTP redirects are disabled. The Windows
client does not access the official CloudKit container or iCloud Keychain and
does not pair with the separately distributed ServerKiln iPhone app or widgets.
See the [Windows guide](windows.md) for installation and removal.

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
