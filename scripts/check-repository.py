#!/usr/bin/env python3
"""Run portable repository checks and expose failures as GitHub annotations."""
import os
from pathlib import Path
import subprocess
import sys
import traceback
import unittest

ROOT = Path(__file__).resolve().parents[1]


def annotate(message):
    if os.environ.get('GITHUB_ACTIONS') == 'true':
        escaped = message[-60000:].replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
        print('::error title=Repository verification failed::' + escaped, flush=True)


def main():
    for arguments in [('check-public-tree.py', '--history'), ('check-docs.py',), ('export-windows-collector.py', '--check')]:
        result = subprocess.run([sys.executable, str(ROOT / 'scripts' / arguments[0]), *arguments[1:]],
                                cwd=ROOT, capture_output=True, text=True, encoding='utf-8', errors='replace',
                                env={**os.environ, 'PYTHONIOENCODING': 'utf-8'})
        print(result.stdout, end='')
        print(result.stderr, end='', file=sys.stderr)
        if result.returncode:
            annotate(' '.join(arguments) + '\n' + result.stdout + result.stderr)
            return result.returncode
    suite = unittest.defaultTestLoader.discover(str(ROOT / 'Tests/RepositoryTests'))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    for test, trace in result.failures + result.errors:
        annotate(test.id() + '\n' + trace)
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding='utf-8', errors='replace')
    try:
        sys.exit(main())
    except Exception:
        trace = traceback.format_exc()
        annotate(trace)
        print(trace, file=sys.stderr)
        sys.exit(1)
