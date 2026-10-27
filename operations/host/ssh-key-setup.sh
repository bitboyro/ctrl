#!/usr/bin/env bash
set -euo pipefail
exec python3 - <<'PY'
import json
import os
from pathlib import Path
import shlex
import re
import subprocess
import sys

key = Path(os.environ['CTRL_PARAM_KEY']).expanduser().resolve()
public = Path(str(key) + '.pub')
if not key.is_file() or not public.is_file():
    raise SystemExit('An existing key pair is required. Create one with ssh-keygen, then pass --key PATH (without .pub).')
text = public.read_text().strip()
if '\n' in text or '\r' in text or '\x00' in text:
    raise SystemExit('Expected one public key line')
fields = text.split()
if len(fields) < 2 or not re.fullmatch(r'(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)', fields[0]):
    raise SystemExit('Expected a plain SSH public key without authorized_keys options')
subprocess.run(['ssh-keygen', '-l', '-f', str(public)], check=True, stdout=subprocess.DEVNULL)
ssh = json.loads(os.environ['CTRL_SSH_ARGS'])
verify = json.loads(os.environ['CTRL_SSH_KEY_ARGS'])
# Override any configured key: verify exactly the pair being installed.
host = verify.pop()
i = 0
while i < len(verify):
    if verify[i] == '-i':
        del verify[i:i+2]
    else:
        i += 1
verify += ['-i', str(key), '-o', 'IdentitiesOnly=yes', '-o', 'PreferredAuthentications=publickey', host, 'true']
# Encrypted keys can be unlocked in ssh-agent; verification never prompts.
script = '''set -eu
umask 077
directory="$HOME/.ssh"
file="$directory/authorized_keys"
[ ! -L "$directory" ] && [ ! -L "$file" ] || { echo 'Refusing symlinked SSH authorization files' >&2; exit 1; }
mkdir -p "$directory"
chmod 700 "$directory"
key=KEY_LITERAL
if [ -f "$file" ] && grep -qxF "$key" "$file"; then
    echo 'Public key already authorized; existing keys retained'
else
    if [ -f "$file" ]; then
        backup=$(mktemp "$directory/authorized_keys.ctrl-backup.XXXXXX")
        cat "$file" > "$backup"
    fi
    printf '\\n%s\\n' "$key" >> "$file"
    chmod 600 "$file"
    echo 'Public key added; existing keys retained'
fi
'''.replace('KEY_LITERAL', shlex.quote(text))
result = subprocess.run(ssh + ['sh -s'], input=script, text=True)
if result.returncode:
    raise SystemExit(result.returncode)
result = subprocess.run(verify)
if result.returncode:
    print('Key was authorized, but key-only verification failed. Existing password login and configuration are unchanged. Check the matching private key or unlock it with ssh-add.', file=sys.stderr)
    raise SystemExit(result.returncode)
print('Key-only login verified. Password login and target configuration are unchanged.')
print('To switch this target, set key to ' + str(key) + ' and remove password_env from its configuration.')
PY
