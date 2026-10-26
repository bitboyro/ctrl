#!/usr/bin/env bash
set -euo pipefail
exec python3 - <<'PYCODE'
import json,os
args=json.loads(os.environ['CTRL_SSH_ARGS'])
args.insert(1,'-t')
# The Python program is read from a heredoc; reconnect SSH stdin to the terminal.
fd=os.open('/dev/tty',os.O_RDONLY)
os.dup2(fd,0)
os.close(fd)
os.execvp(args[0],args+['cd '+__import__('shlex').quote(os.environ['CTRL_TARGET_CWD'])+' && exec "${SHELL:-bash}" -l'])
PYCODE
