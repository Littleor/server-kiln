#!/usr/bin/env python3
"""Run the unchanged Swift suite and expose its failure detail in CI annotations."""
from collections import deque
import os
from pathlib import Path
import subprocess
import sys


def main():
    tail = deque(maxlen=200)
    failures = deque(maxlen=30)
    with subprocess.Popen(['swift', 'test', '--force-resolved-versions'],
                          cwd=Path(__file__).resolve().parents[1],
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, encoding='utf-8', errors='replace') as process:
        for line in process.stdout:
            print(line, end='', flush=True)
            tail.append(line)
            if any(marker in line.lower() for marker in ('error:', 'xctassert', 'fatal error', 'failed', 'crashed')):
                failures.append(line)
        code = process.wait()
    if code and os.environ.get('GITHUB_ACTIONS') == 'true':
        # GitHub truncates annotation text; put actual diagnostics before routine output.
        message = (''.join(failures)[:3000] + '\nFinal output:\n' + ''.join(tail)[-900:])[:4000]
        escaped = message.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
        print('::error title=Swift verification failed::' + escaped, flush=True)
    return code


if __name__ == '__main__':
    sys.exit(main())
