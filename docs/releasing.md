# Releasing ServerKiln

Official releases are built on a trusted maintainer Mac. Private signing keys
stay outside Git and GitHub Actions. CI creates a **draft** after a version tag
passes validation; it never publishes the draft automatically. The Windows
artifact is currently unsigned and must be identified as such when the
maintainer reviews the cross-platform release.

## Prepare

1. Update `VERSION`, `BUILD_NUMBER` and `project.yml` together.
2. Update `CHANGELOG.md` and add `docs/releases/v<version>.md`.
3. Run tests, build the universal app, inspect both languages and run public-tree,
   documentation and Gitleaks checks. Use only synthetic screenshot data.
4. Commit the reviewed changes and create an annotated tag at that commit.

```bash
swift test --force-resolved-versions
scripts/build-app.sh
python3 scripts/check-public-tree.py --history
python3 scripts/check-docs.py
gitleaks git --redact --no-banner --log-opts=--all
git tag -a "v$(cat VERSION)" -m "ServerKiln $(cat VERSION)"
```

## Sign and notarize

The following signing steps apply to the Mac app. The independent Windows package
is built and verified in Actions as described in the Windows section below.

Install the Developer ID Application certificate and matching provisioning
profile in the maintainer's keychain/profile store. Keep the App Store Connect
API private key outside the checkout. Set these environment variables (or source
an external file through `ASC_ENV`):

| Variable | Meaning |
| --- | --- |
| `APPLE_TEAM_ID` | Apple developer team for the official app |
| `ASC_AUTH_KEY_PATH` | Absolute path to the App Store Connect `.p8` key |
| `ASC_AUTH_KEY_ID` | API key identifier |
| `ASC_AUTH_KEY_ISSUER_ID` | API issuer identifier |
| `DEVELOPER_ID_APPLICATION` | Optional signing identity; defaults to `Developer ID Application` |
| `MAC_PROVISIONING_PROFILE` | Optional profile; defaults to `ServerKiln macOS Developer ID` |

```bash
scripts/release-mac.sh
```

The script builds both architectures, exports with production iCloud entitlements,
checks production CloudKit, push and keychain entitlements, notarizes and staples
the app, then signs/notarizes/staples a DMG. The ZIP contains
the stapled app too. It verifies signatures and Gatekeeper assessment and writes:

```text
build/release/v<version>/
  ServerKiln-<version>-universal.dmg
  ServerKiln-<version>-universal.zip
  SHA256SUMS
```

Existing output is not overwritten. If the app passed notarization but packaging
failed, resume with `scripts/package-release.sh /absolute/path/to/export/ServerKiln.app
/absolute/path/to/build/release/v<version>` using the same signing environment.
Otherwise move an incomplete build aside before retrying. Archives and export metadata in that directory are maintainer-only;
upload only the two installers and checksum file.

## Publish

Push the reviewed branch and annotated tag explicitly after approval. The tag
workflow validates the source and prepares a release draft. Wait for CI and the
tag workflow to pass, then:

```bash
scripts/publish-release.sh
```

This verifies the pushed tag, clean working tree, checksums and notarization,
then attaches the installers to a **draft**. It refuses to overwrite a published
release or existing assets. Review the draft notes and downloads before the
explicit final publication:

```bash
gh release edit "v$(cat VERSION)" --repo Littleor/server-kiln --draft=false --latest
```

Finally, verify the public release page, download both assets and compare their
checksums. Never use an artifact built from unrelated source or private app
targets. Do not rewrite a published tag; issue a new version for corrections.

## Windows artifacts

The tag workflow builds Windows using the SDK pinned in `global.json`, runs the
core / WPF checks and packages a self-contained x64 ZIP with runtime notices and
its SHA-256 manifest. Both Mac verification and Windows packaging must succeed
before the draft is prepared. The Windows upload job independently verifies the
downloaded artifact with `scripts/check-windows-package.py` before attaching:

- `ServerKiln-<version>-win-x64.zip`
- `ServerKiln-<version>-win-x64.zip.sha256`

It only uploads to a draft and never clobbers existing assets. An already public
release is left unchanged. Rerunning an upload with duplicate asset names fails
instead of replacing a reviewed download; inspect the draft before resolving it.
The maintainer still reviews all platform artifacts before final publication.

For a local Windows build:

```powershell
scripts/build-windows.ps1 -Package -Snapshots
python scripts/check-windows-package.py --directory dist --version (Get-Content VERSION -Raw).Trim()
```

The current Windows distribution is unsigned and updates by manual replacement.
Do not label it as Authenticode signed. Future Windows signing should use a
maintainer-owned credential outside the checkout; Apple signing keys are unrelated.
