# Contributing

Thank you for helping improve ServerKiln. Issues and pull requests in English
or Chinese are welcome. Please discuss larger changes in an issue first.

## Set up

Install Xcode 26.3 or newer, select its developer directory, then follow the
[development guide](docs/development.md). Run `swift test --force-resolved-versions`
and `scripts/build-app.sh` before opening a pull request. XcodeGen is only needed
for the Xcode project and official signing workflow.

## Keep changes focused

- Put parsing, state transitions and persistence logic in the core module.
- Keep network and UI work separate; avoid blocking the main actor.
- Add regression coverage for changed behavior, especially SSH, parsing,
  key deployment and history migrations.
- Keep English and Simplified Chinese translations in sync. Use
  `String(appLocalized:)` for explicit strings and SwiftUI localization for views.
- Use `--snapshot` with demo data for screenshots; inspect light and dark modes.
- Commit messages use `feat:`, `fix:`, `docs:`, `refactor:`, `test:` or `chore:`
  followed by a concise English description.

## Public repository boundary

This repository maintains the Mac app and the common modules used by its Mac
features. Do not add the separately distributed companion app, widget targets,
private planning material, assistant instructions, credentials or deployment
records. Run `python3 scripts/check-public-tree.py --history` and
`python3 scripts/check-docs.py`. CI also scans Git history with Gitleaks.

Never put real SSH keys, hostnames, IP addresses, usernames or sensitive process
arguments in a bug report. Use fictional hosts under `example.com`, documentation
IP ranges and synthetic demo workloads. A screenshot can disclose information
even when no source file does.

## Pull requests

Explain the concrete problem, the resulting behavior and what you tested.
Include screenshots for visible changes. Update user documentation when the
behavior changes, and third-party notices when dependencies change.

Contributions you submit for inclusion are licensed under the project's MIT
license. Third-party code must retain its own license and attribution. By
participating, you agree to the [code of conduct](CODE_OF_CONDUCT.md).
