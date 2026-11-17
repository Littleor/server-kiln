#!/usr/bin/env python3
"""Verify the Windows release archive without executing it or extracting paths."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import struct
import zipfile

REQUIRED = {'ServerKiln.exe', 'ServerKiln.dll', 'ServerKiln.Windows.Core.dll',
            'ServerKiln.runtimeconfig.json', 'coreclr.dll', 'PresentationFramework.dll',
            'LICENSE', 'THIRD_PARTY_NOTICES.md', 'install.ps1', 'WindowsShortcuts.cs', 'WINDOWS.md',
            'Licenses/dotnet-LICENSE.txt', 'Licenses/dotnet-ThirdPartyNotices.txt'}


def verify(directory, version):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Invalid release version')
    archive = Path(directory) / f'ServerKiln-{version}-win-x64.zip'
    checksum = archive.with_suffix('.zip.sha256').read_text(encoding='ascii').split()
    if len(checksum) != 2 or checksum[1] != archive.name:
        raise ValueError('Checksum manifest must name exactly this archive')
    with archive.open('rb') as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
        actual = digest.hexdigest()
    if actual != checksum[0]:
        raise ValueError('Windows ZIP checksum mismatch')
    with zipfile.ZipFile(archive) as package:
        names = package.namelist()
        if len(set(name.casefold() for name in names)) != len(names):
            raise ValueError('Duplicate Windows archive paths')
        for name in names:
            path = PurePosixPath(name)
            if path.is_absolute() or '..' in path.parts or '\\' in name or ':' in name:
                raise ValueError('Unsafe Windows archive path')
            if path.name.casefold() in {'settings.json', 'history.sqlite', 'bark-key.dat', 'known_hosts', 'id_rsa', 'id_ed25519', 'id_ecdsa'} or path.suffix.casefold() in {'.pem', '.key', '.p12', '.p8', '.pfx', '.ppk'}:
                raise ValueError('Private runtime data must not be packaged')
        missing = REQUIRED - set(names)
        if missing:
            raise ValueError('Missing Windows files: ' + ', '.join(sorted(missing)))
        if package.testzip() is not None:
            raise ValueError('Windows ZIP has corrupt data')
        executable = package.read('ServerKiln.exe')
        if len(executable) < 64 or executable[:2] != b'MZ':
            raise ValueError('Windows application is not a PE executable')
        pe = struct.unpack_from('<I', executable, 60)[0]
        if executable[pe:pe + 4] != b'PE\0\0' or len(executable) < pe + 6 or struct.unpack_from('<H', executable, pe + 4)[0] != 0x8664:
            raise ValueError('Windows package must contain the x64 application host')
        runtime = json.loads(package.read('ServerKiln.runtimeconfig.json'))['runtimeOptions']
        frameworks = {item['name'] for item in runtime.get('includedFrameworks', [])}
        if not {'Microsoft.NETCore.App', 'Microsoft.WindowsDesktop.App'} <= frameworks:
            raise ValueError('Windows package must include its desktop runtime')
        for prefix in ('microsoft.netcore.app.runtime.win-x64-LICENSE', 'microsoft.windowsdesktop.app.runtime.win-x64-LICENSE'):
            if not any(name.startswith('Licenses/' + prefix) for name in names):
                raise ValueError('Missing Microsoft runtime pack license')
    return actual


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    print('Windows archive verified: ' + verify(args.directory, args.version))


if __name__ == '__main__':
    main()
