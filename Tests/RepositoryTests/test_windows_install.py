"""Exercise the real installer in isolated directories; never alter user shortcuts."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/install-windows.ps1'


@unittest.skipUnless(os.name == 'nt', 'Windows shell shortcuts require Windows')
class WindowsInstallTests(unittest.TestCase):
    def test_install_update_shortcuts_and_remove_preserve_user_data(self):
        with tempfile.TemporaryDirectory(prefix='serverkiln-installer-test-') as directory:
            root = Path(directory).resolve()
            source = root / 'package with spaces'
            source.mkdir()
            program = root / '安装 with spaces'
            desktop, menu = root / 'desktop', root / 'menu'
            user_data = root / 'user data'
            user_data.mkdir()
            sentinel = user_data / 'settings.json'
            sentinel.write_text('{"synthetic": true}', encoding='utf-8')
            system = Path(os.environ['WINDIR']) / 'System32'
            shutil.copy2(system / 'where.exe', source / 'ServerKiln.exe')
            version_one = (source / 'ServerKiln.exe').read_bytes()
            (source / 'runtime').mkdir()
            (source / 'runtime/library.dll').write_bytes(b'fixture dependency')
            command = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(SCRIPT),
                       '-SourceDirectory', str(source), '-InstallDirectory', str(program),
                       '-DesktopDirectory', str(desktop), '-StartMenuDirectory', str(menu)]
            def install():
                result = subprocess.run(command, capture_output=True)
                self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode('utf-8', errors='replace'))
            install()
            self.assertEqual((program / 'ServerKiln.exe').read_bytes(), version_one)
            self.assertTrue((program / 'runtime/library.dll').exists())
            for folder in (desktop, menu):
                link = folder / 'ServerKiln.lnk'
                quoted = str(link).replace("'", "''")
                helper = str(SCRIPT.parent / 'WindowsShortcuts.cs').replace("'", "''")
                inspect = ("[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); "
                           f"Add-Type -Path '{helper}'; "
                           f"$link = [ServerKilnSetup.Shortcuts]::Inspect('{quoted}'); "
                           "[PSCustomObject]@{target=$link.TargetPath;directory=$link.WorkingDirectory;arguments=$link.Arguments} | ConvertTo-Json -Compress")
                result = subprocess.run(['powershell.exe', '-NoProfile', '-Command', inspect], check=True,
                                        capture_output=True, encoding='utf-8')
                properties = json.loads(result.stdout)
                self.assertEqual(os.path.normcase(properties['target']), os.path.normcase(str(program / 'ServerKiln.exe')))
                self.assertEqual(properties['arguments'], '')
            shutil.copy2(system / 'hostname.exe', source / 'ServerKiln.exe')
            version_two = (source / 'ServerKiln.exe').read_bytes()
            self.assertNotEqual(version_one, version_two)
            install()
            self.assertEqual((program / 'ServerKiln.exe').read_bytes(), version_two)
            self.assertEqual(sentinel.read_text(encoding='utf-8'), '{"synthetic": true}')
            self.assertTrue(program.resolve().is_relative_to(root))
            shutil.rmtree(program)
            for folder in (desktop, menu):
                (folder / 'ServerKiln.lnk').unlink()
            self.assertTrue(sentinel.exists())


if __name__ == '__main__':
    unittest.main()
