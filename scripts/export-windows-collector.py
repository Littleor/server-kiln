#!/usr/bin/env python3
"""Export the unchanged Swift collector for Windows; --check detects drift."""
from pathlib import Path
import argparse
import re

ROOT = Path(__file__).resolve().parents[1]


def collector():
    source = (ROOT / 'Sources/ServerKilnCore/RemoteScript.swift').read_text(encoding='utf-8')
    blocks = re.findall(r'#"""\n(.*?)\n"""#', source, re.S)
    if len(blocks) != 5 or 'while read -r _; do snap </dev/null; done' not in blocks[4]:
        raise ValueError('Swift collector structure changed; review the Windows exporter.')
    return '\n'.join([blocks[0], blocks[3], blocks[1], blocks[4]]) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    target = ROOT / 'Resources/Collector/collect-loop.sh'
    expected = collector()
    if args.check:
        if not target.exists() or target.read_text(encoding='utf-8') != expected:
            raise SystemExit('Collector differs from Swift. Run python scripts/export-windows-collector.py')
        print('Windows collector matches the Swift source.')
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(expected, encoding='utf-8', newline='\n')


if __name__ == '__main__':
    main()
