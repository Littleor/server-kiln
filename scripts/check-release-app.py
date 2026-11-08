#!/usr/bin/env python3
"""Validate official signing entitlements, version and packaged resources."""
from pathlib import Path
import plistlib
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
app = Path(sys.argv[1])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
entitlements = plistlib.loads(subprocess.check_output(
    ['codesign', '-d', '--entitlements', '-', '--xml', str(app)], stderr=subprocess.DEVNULL))
checks = {
    'version': info.get('CFBundleShortVersionString') == (root / 'VERSION').read_text().strip(),
    'build': info.get('CFBundleVersion') == (root / 'BUILD_NUMBER').read_text().strip(),
    'bundle identifier': info.get('CFBundleIdentifier') == 'cn.littleor.serverkiln',
    'minimum system': info.get('LSMinimumSystemVersion') == '14.0',
    'CloudKit service': 'CloudKit' in entitlements.get('com.apple.developer.icloud-services', []),
    'CloudKit container': 'iCloud.cn.littleor.serverkiln' in entitlements.get('com.apple.developer.icloud-container-identifiers', []),
    'production iCloud': entitlements.get('com.apple.developer.icloud-container-environment') == 'Production',
    'production push': entitlements.get('com.apple.developer.aps-environment') == 'production',
    'no debugger entitlement': not entitlements.get('com.apple.security.get-task-allow', False),
    'no app extensions': not list(app.rglob('*.appex')),
}
prefix = entitlements.get('com.apple.developer.team-identifier', '') + '.'
for group in ['cn.littleor.serverkiln.shared', 'cn.littleor.serverkiln.terminal']:
    checks[f'keychain group {group}'] = prefix + group in entitlements.get('keychain-access-groups', [])
for lang in ['en', 'zh-Hans']:
    checks[f'{lang} localization'] = (app / f'Contents/Resources/{lang}.lproj/Localizable.strings').is_file()
for name in ['LICENSE', 'THIRD_PARTY_NOTICES.md', 'Licenses/BoringSSL-LICENSE.txt']:
    checks[f'license {name}'] = (app / 'Contents/Resources' / name).is_file()
failed = [name for name, valid in checks.items() if not valid]
if failed:
    print('Invalid release app: ' + ', '.join(failed), file=sys.stderr)
    sys.exit(1)
print('Official app version, production entitlements and resources verified.')
