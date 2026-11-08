#!/usr/bin/env python3
"""Fail closed if private source, authoring files, credentials or artifacts enter Git."""
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DIRECTORIES = {'.github', 'Config', 'Resources', 'Sources', 'Tests', 'Vendor', 'docs', 'scripts'}
ROOT_FILES = {'.gitignore', '.gitattributes', '.gitleaks.toml', 'Package.swift', 'Package.resolved', 'project.yml',
              'VERSION', 'BUILD_NUMBER', 'README.md', 'README.zh-CN.md', 'LICENSE',
              'THIRD_PARTY_NOTICES.md', 'CONTRIBUTING.md', 'SECURITY.md', 'SUPPORT.md',
              'CODE_OF_CONDUCT.md', 'CHANGELOG.md'}


def private_path(name):
    path = PurePosixPath(name)
    parts = [p.casefold() for p in path.parts]
    if len(parts) == 1 and name not in ROOT_FILES:
        return True
    if len(parts) > 1 and path.parts[0] not in DIRECTORIES:
        return True
    for part in parts:
        if part in {'ios', '.claude', '.codex', '.cursor', 'appstore.md', 'deployment.md'}:
            return True
        if part.startswith(('prd', 'prompt', '.env')) or (part.startswith('agent') and part.endswith('.md')):
            return True
    return path.suffix.casefold() in {'.p8', '.p12', '.pem', '.key', '.mobileprovision',
                                     '.provisionprofile', '.dmg', '.zip', '.ipa'}


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT).decode()


def main():
    names = set(filter(None, git('ls-files', '-z', '--cached', '--others', '--exclude-standard').split('\0')))
    # Checking the complete history also catches files deleted from the current tree.
    if '--history' in sys.argv:
        for line in git('rev-list', '--objects', '--all').splitlines():
            if ' ' in line:
                name = line.split(' ', 1)[1]
                # Tree entries (directory names) have no file extension.
                if '/' in name or '.' in PurePosixPath(name).name:
                    names.add(name)
    failures = []
    secret = re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|'
                        r'\bgh[pousr]_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{40,}|'
                        r'/Users/[A-Za-z0-9._-]+/')
    for name in sorted(names):
        if private_path(name):
            failures.append(f'Private or unexpected path: {name}')
        file = ROOT / name
        if file.is_symlink():
            failures.append(f'Symlink must be reviewed and removed: {name}')
        elif file.is_file() and file.suffix in {'.swift', '.md', '.yml', '.yaml', '.json', '.sh', '.py', '.xcstrings'}:
            if not name.startswith('Vendor/') and secret.search(file.read_text(errors='replace')):
                failures.append(f'Credential or personal path pattern: {name}')
    if failures:
        print('\n'.join(failures), file=sys.stderr)
        return 1
    print(f'Public tree verified: {len(names)} paths; no private paths or credential patterns.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
