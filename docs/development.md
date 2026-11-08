# Development

## Toolchain

- macOS with Xcode 26.3 / Swift 6.2 or newer selected via `xcode-select`.
- Git and the system Python 3 for dependency-free validation helpers.
- XcodeGen (`brew install xcodegen`) only when generating an Xcode project.
- Gitleaks (`brew install gitleaks`) for the same secret scan used by CI.

The app targets macOS 14+. The lockfile pins dependencies that require the newer
toolchain. Swift code currently uses Swift 5 language mode. To run helper scripts
with an isolated Python interpreter, `uv run --no-project --python 3.12
scripts/check-docs.py` works without installing project dependencies.

## Build and test

```bash
swift test --force-resolved-versions
scripts/build-app.sh debug
open dist/ServerKiln.app
python3 scripts/check-public-tree.py --history
python3 scripts/check-docs.py
gitleaks git --redact --no-banner --log-opts=--all
```

The build script accepts `debug` or `release` (default), builds arm64 and x86_64,
compiles string catalogs, embeds notices and signs the app ad hoc. It requires
no Apple developer membership. It does not publish anything.

Local SSH integration tests start a disposable `sshd` on loopback, generate
temporary keys and remove their temporary files afterward. They skip if the host
cannot run that daemon. Inspect skips before claiming that SSH coverage passed.
No test needs production credentials or a real GPU server.

For an unsigned Xcode build:

```bash
xcodegen generate
xcodebuild -project ServerKiln.xcodeproj -scheme ServerKiln-macOS \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

## Diagnostic commands

```bash
# Reads a host that you explicitly select; the result may contain private data.
swift run ServerKiln --probe gpu-lab

# Synthetic screenshots, isolated from normal settings/history.
dist/ServerKiln.app/Contents/MacOS/ServerKiln --snapshot build/screenshots/en --language en
dist/ServerKiln.app/Contents/MacOS/ServerKiln --snapshot build/screenshots/zh --language zh-Hans

# Existing visual layout regression checks.
dist/ServerKiln.app/Contents/MacOS/ServerKiln --snapshot build/layout --check-layout
dist/ServerKiln.app/Contents/MacOS/ServerKiln --snapshot build/layout --check-menubar
```

Use the ad-hoc build for screenshots. Omitting SSH targets uses only synthetic
data. Do not pass production hosts when producing public screenshots.

## Localization and versioning

Chinese source strings are keys in `Resources/Localizable.xcstrings`; English
translations and explicit `zh-Hans` source values live in that catalog. Keep the
source values equal to their keys so both language bundles are emitted, including
when the app runs on an English system. Build a bundle to verify both languages.
Direct `swift run` does not package the catalog. Add translations for new strings
and run the documentation checker.

Keep `VERSION`, `BUILD_NUMBER` and the matching fields in `project.yml` aligned.
The checker rejects mismatches. Lockfile updates and vendor patches should be
reviewed explicitly; see [vendor notes](../Vendor/swift-nio-ssh/README.serverkiln.md).
