"""Release artifact integrity, path safety and runtime inclusion checks."""
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

script = Path(__file__).resolve().parents[2] / 'scripts/check-windows-package.py'
spec = importlib.util.spec_from_file_location('windows_package', script)
package_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package_check)


class WindowsPackageTests(unittest.TestCase):
    def fixture(self, directory, extra=None, omit=None):
        archive = Path(directory) / 'ServerKiln-1.2.3-win-x64.zip'
        files = {name: b'fixture' for name in package_check.REQUIRED if name != omit}
        exe = bytearray(256)
        exe[:2] = b'MZ'
        struct.pack_into('<I', exe, 60, 128)
        exe[128:132] = b'PE\0\0'
        struct.pack_into('<H', exe, 132, 0x8664)
        files['ServerKiln.exe'] = bytes(exe)
        files['ServerKiln.runtimeconfig.json'] = json.dumps({'runtimeOptions': {'includedFrameworks': [
            {'name': 'Microsoft.NETCore.App'}, {'name': 'Microsoft.WindowsDesktop.App'}]}}).encode()
        files['Licenses/microsoft.netcore.app.runtime.win-x64-LICENSE.TXT'] = b'fixture license'
        files['Licenses/microsoft.windowsdesktop.app.runtime.win-x64-LICENSE'] = b'fixture license'
        files.update(extra or {})
        with zipfile.ZipFile(archive, 'w') as package:
            for name, data in files.items():
                package.writestr(name, data)
        self.manifest(archive)
        return archive

    @staticmethod
    def manifest(archive):
        archive.with_suffix('.zip.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name, encoding='ascii')

    def test_valid_self_contained_package(self):
        with tempfile.TemporaryDirectory() as directory:
            self.fixture(directory)
            self.assertEqual(len(package_check.verify(directory, '1.2.3')), 64)

    def test_corrupt_archive_or_wrong_manifest_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = self.fixture(directory)
            archive.write_bytes(archive.read_bytes() + b'tampered')
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                package_check.verify(directory, '1.2.3')

    def test_missing_runtime_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            self.fixture(directory, omit='PresentationFramework.dll')
            with self.assertRaisesRegex(ValueError, 'Missing Windows files'):
                package_check.verify(directory, '1.2.3')

    def test_private_data_and_unsafe_paths_are_rejected(self):
        for name in ['../outside.txt', 'C:/outside.txt', 'settings.json', 'bark-key.dat', 'identity.pem', 'signing.pfx', 'id_ed25519']:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                self.fixture(directory, {name: b'synthetic'})
                with self.assertRaises(ValueError):
                    package_check.verify(directory, '1.2.3')

    def test_wrong_architecture_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            self.fixture(directory, {'ServerKiln.exe': b'MZ invalid'})
            with self.assertRaisesRegex(ValueError, 'PE executable'):
                package_check.verify(directory, '1.2.3')


if __name__ == '__main__':
    unittest.main()
