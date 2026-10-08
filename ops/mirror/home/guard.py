#!/usr/bin/env python3
import os
import pathlib
import subprocess

VOLUME = pathlib.Path('/mnt/storage')
ROOT = VOLUME / 'forkop-mirror'
EXPECTED_UUID = '97ac41f2-6e9e-4c36-9bdd-161922a0de2b'

def guard():
    if not os.path.ismount(VOLUME):
        raise RuntimeError('Mirror disk is not mounted; refusing to use the system disk')
    uuid = subprocess.check_output(['findmnt', '-n', '-o', 'UUID', '--target', str(VOLUME)], text=True).strip()
    if uuid != EXPECTED_UUID or ROOT.is_symlink() or ROOT.resolve() != ROOT:
        raise RuntimeError('Unexpected mirror volume/path')
    if (ROOT / '.forkop-mirror-volume').read_text().strip() != EXPECTED_UUID:
        raise RuntimeError('Mirror volume marker is missing or invalid')

if __name__ == '__main__':
    guard()
