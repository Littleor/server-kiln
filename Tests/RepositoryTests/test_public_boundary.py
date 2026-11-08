"""Exercise the publication gate against private files hidden in past commits."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

script = Path(__file__).resolve().parents[2] / 'scripts/check-public-tree.py'
spec = importlib.util.spec_from_file_location('boundary', script)
boundary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(boundary)


class PublicBoundaryTests(unittest.TestCase):
    def test_private_paths_are_rejected_even_when_nested_or_case_changed(self):
        for path in ['iOS/App/main.swift', 'Sources/IOS/main.swift', 'docs/PRD.md',
                     'docs/Prompt/Agent.md', 'docs/AGENTS.MD', 'docs/Agent-private.md',
                     'Config/team.p12', 'docs/Deployment.md', 'Sources/.env.local']:
            with self.subTest(path=path):
                self.assertTrue(boundary.private_path(path))
        for path in ['Sources/ServerKiln/PhoneSync.swift', 'Config/ServerKiln.entitlements',
                     'docs/security-and-privacy.md', 'Resources/Licenses/swift-nio-LICENSE.txt']:
            self.assertFalse(boundary.private_path(path))

    def test_deleted_private_file_is_still_rejected_from_history(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            (root / 'scripts/check-public-tree.py').write_bytes(script.read_bytes())
            def git(*args):
                subprocess.run(['git', *args], cwd=root, check=True, capture_output=True)
            git('init', '-q')
            git('config', 'user.name', 'Boundary Test')
            git('config', 'user.email', 'test@example.com')
            (root / 'docs').mkdir()
            private = root / 'docs/PRD.md'
            private.write_text('Private planning fixture')
            git('add', '.')
            git('commit', '-qm', 'test: add fixture')
            private.unlink()
            git('add', '-u')
            git('commit', '-qm', 'test: remove fixture')
            result = subprocess.run(['python3', 'scripts/check-public-tree.py', '--history'],
                                    cwd=root, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('docs/PRD.md', result.stderr)


if __name__ == '__main__':
    unittest.main()
