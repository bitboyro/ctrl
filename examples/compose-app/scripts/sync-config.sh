#!/usr/bin/env bash
set -euo pipefail
exec python3 - <<'PY'
import json,os,shlex,subprocess
from pathlib import Path
source=Path(os.environ['CTRL_PROJECT_DIR'])/'docker-compose.yml'
if not source.is_file(): raise SystemExit('Example Compose file not found')
ssh=json.loads(os.environ['CTRL_SSH_ARGS'])
raise SystemExit(subprocess.call(['rsync','-az','--protect-args','-e',shlex.join(ssh[:-1]),'--',str(source),ssh[-1]+':/srv/demo-app/docker-compose.yml']))
PY
