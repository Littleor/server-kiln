# Changelog

## Unreleased — Windows client

- Light Windows interface with a persistent fleet sidebar, selected-server details,
  per-GPU meters, expandable task / process rows and grouped settings.
  Windows uses a fixed light palette and accepts legacy settings with a dark preference.
- Independent .NET 10 / WPF tray client with native Windows OpenSSH sessions,
  GPU/CPU monitoring, SQLite history, recent jobs and debounced notifications.
- Optional iPhone notifications through Bark with a DPAPI-protected device key.
  Original iPhone app / widget / iCloud pairing is not connected by this client.
- Chinese and English UI, a light interface, user-level installation and login startup.
- Shared Swift/C# parsing fixtures, collector export verification, Windows CI,
  WPF smoke tests and self-contained Windows packaging with checksums and notices.
- CRLF normalization in the shared Swift snapshot parser, fixing empty host and
  process results exposed by the cross-platform fixture corpus.
- UTF-8 documentation validation and portable repository test execution on Windows.
- First-connection fingerprint confirmation with a persistent Windows trust store,
  including configurations that discard known hosts; per-server private-key file
  selection and distinct guidance for host-key, identity and file-permission errors.
- User-level installation creates desktop and Start menu shortcuts; reopening a
  shortcut restores the running tray window through a local per-user channel.
- Live ten-minute history, per-GPU utilization / VRAM charts and Mac-aligned range
  buckets; valid custom OpenSSH trust stores remain inherited.
- Pinned Windows SDK, synthetic snapshot export, isolated installer upgrade tests,
  release artifact verification and automatic attachment to draft releases.

## 1.0.6

See [release notes](docs/releases/v1.0.6.md).

## 1.0.4

See [release notes](docs/releases/v1.0.4.md).

## 1.0.3

See [release notes](docs/releases/v1.0.3.md).

## 1.0.2 — 2026-11-08

First public source release of ServerKiln for macOS.

- Native menu bar fleet monitoring, per-GPU metrics, task history, local charts
  and debounced notifications.
- Existing SSH configuration import, CPU-only hosts and configurable polling.
- English and Simplified Chinese, light/dark appearance and dual-row summaries.
- Mac-side iPhone companion setup and iCloud relay in the official signed build.
- MIT-licensed Mac source with an independent public history and documented
  third-party dependencies.
- Universal app packaging with compiled localization resources and license notices.
- Explicit source-language resources and localized history captions for reliable
  language switching on either Chinese or English system settings.
- Developer ID signing, notarization, DMG/ZIP artifacts and SHA-256 checksums.
- Contributor guides, issue templates, CI and public-source boundary checks.
- Public screenshots regenerated from synthetic data.

The companion app and widgets are separate products and are not part of this
source release. Earlier builds predate this public repository.
