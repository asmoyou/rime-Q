#!/usr/bin/env python3
"""Render the native installer states without installing or touching live input services."""
from pathlib import Path
import struct
import subprocess
import build_windows

ROOT = Path(__file__).resolve().parents[1]


def png_size(path):
    data = path.read_bytes()
    if not data.startswith(b'\x89PNG\r\n\x1a\n'):
        raise AssertionError(f'{path.name} is not a PNG')
    return struct.unpack('>II', data[16:24])


def main():
    output = ROOT / 'build-windows/Installer.UI.Preview.exe'
    icon = ROOT / 'build-windows/RimeQ.ico'
    if not icon.is_file():
        build_windows.icon(icon)
    build_windows.csharp(output, [ROOT / 'windows/installer/Setup.cs'], 9140,
                         main='RimeQ.Setup', console=True)
    destination = ROOT / 'artifacts/windows-installer-ui'
    destination.mkdir(parents=True, exist_ok=True)
    modes = ['install-light', 'install-dark', 'upgrade-light', 'current-light',
             'complete-light', 'error-dark', 'uninstall-light']
    for mode in modes:
        image = destination / f'{mode}.png'
        subprocess.run([str(output), '--render', str(image), mode], check=True, timeout=20)
        if png_size(image) != (720, 560) or image.stat().st_size < 12_000:
            raise AssertionError(f'{mode} render is blank or has unstable dimensions')
    print('PASS native Windows installer UI: install/upgrade/current/complete/error/uninstall states, light/dark, stable 720x560 layout')


if __name__ == '__main__':
    main()
