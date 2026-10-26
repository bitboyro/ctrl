#!/usr/bin/env bash
# Install verified ctrl executable. Usage: install.sh [vVERSION | --from DIST_DIR]
set -euo pipefail
exec python3 - "$@" <<'PY'
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.request

args = sys.argv[1:]
if args in (['--help'], ['-h']):
    print('install.sh [vVERSION | --from DIST_DIR]\nInstalls verified ctrl to CTRL_BIN_DIR (default ~/.local/bin). No profile/skill changes.')
    raise SystemExit(0)
if args and args[0] == '--from':
    if len(args) != 2:
        raise SystemExit('Usage: install.sh --from DIST_DIR')
    source = Path(args[1]).resolve()
    payload = (source / 'ctrl').read_bytes()
    checksum = (source / 'ctrl.sha256').read_text()
else:
    if len(args) > 1 or (args and not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', args[0])):
        raise SystemExit('Usage: install.sh [vVERSION | --from DIST_DIR]')
    base = 'https://github.com/bitboyro/ctrl/releases/'
    base += 'download/' + args[0] + '/' if args else 'latest/download/'
    with urllib.request.urlopen(base + 'ctrl.sha256', timeout=30) as response:
        checksum = response.read(4096).decode()
    with urllib.request.urlopen(base + 'ctrl', timeout=60) as response:
        payload = response.read(10_000_001)
expected = checksum.split()[0]
if not re.fullmatch(r'[a-fA-F0-9]{64}', expected) or len(payload) > 10_000_000 or hashlib.sha256(payload).hexdigest() != expected:
    raise SystemExit('Checksum mismatch: not installed')
directory = Path(os.environ.get('CTRL_BIN_DIR', '~/.local/bin')).expanduser().resolve()
directory.mkdir(parents=True, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix='.ctrl-install-', dir=directory)
try:
    with os.fdopen(fd, 'wb') as stream:
        stream.write(payload)
    os.chmod(temporary, 0o755)
    result = subprocess.run([sys.executable, temporary, '--version'], capture_output=True, text=True, timeout=10)
    if result.returncode or not result.stdout.startswith('ctrl '):
        raise SystemExit('Downloaded executable failed its sanity check')
    os.replace(temporary, directory / 'ctrl')
    print(result.stdout.strip() + ' installed: ' + str(directory / 'ctrl'))
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
