#!/usr/bin/env bash
set -euo pipefail
exec python3 - <<'PYCODE'
import json,os,shlex,subprocess
ssh=json.loads(os.environ['CTRL_SSH_ARGS'])
args=['rsync','-az','--protect-args','-e',shlex.join(ssh[:-1])]
if os.environ['CTRL_PARAM_DELETE']=='true': args.append('--delete')
source=os.environ['CTRL_PARAM_SOURCE']
args += ['--',source,ssh[-1]+':'+os.environ['CTRL_PARAM_DESTINATION']]
raise SystemExit(subprocess.call(args))
PYCODE
