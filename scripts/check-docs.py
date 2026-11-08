#!/usr/bin/env python3
"""Check local Markdown links and version metadata without network access."""
from pathlib import Path
import json
import re
import sys
from urllib.parse import unquote

root = Path(__file__).resolve().parents[1]
errors = []
for file in list(root.glob('*.md')) + list((root / 'docs').rglob('*.md')):
    text = file.read_text()
    links = re.findall(r'\]\(([^\s)]+)\)', text)
    links += re.findall(r'(?:src|href)="([^"]+)"', text)
    for target in links:
        if ':' in target or target.startswith('#'):
            continue
        path = unquote(target.split('#')[0])
        if not (file.parent / path).exists():
            errors.append(f'{file.relative_to(root)}: missing link {target}')
version = (root / 'VERSION').read_text().strip()
build = (root / 'BUILD_NUMBER').read_text().strip()
project = (root / 'project.yml').read_text()
if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not build.isdigit():
    errors.append('Invalid VERSION or BUILD_NUMBER')
for key, value in [('MARKETING_VERSION', version), ('CURRENT_PROJECT_VERSION', build)]:
    if f'{key}: "{value}"' not in project:
        errors.append(f'project.yml {key} does not match its version file')
catalog = json.loads((root / 'Resources/Localizable.xcstrings').read_text())
for key, entry in catalog['strings'].items():
    if entry.get('extractionState') == 'stale':
        continue
    if re.search(r'[\u4e00-\u9fff]', key) and 'en' not in entry.get('localizations', {}):
        errors.append(f'Missing English localization: {key}')
    if entry.get('localizations', {}).get('zh-Hans', {}).get('stringUnit', {}).get('value') != key:
        errors.append(f'Missing explicit source-language localization: {key}')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('Local documentation links, versions and localization coverage verified.')
