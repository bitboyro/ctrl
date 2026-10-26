#!/usr/bin/env bash
set -euo pipefail
exec python3 - <<'PY'
import json, os
from pathlib import Path
root = Path(os.environ['CTRL_PROJECT_DIR'])
files = sorted(p.name for p in root.iterdir() if p.is_file() and not p.name.startswith('.'))
if os.environ['CTRL_PARAM_FORMAT'] == 'json':
    print(json.dumps({'project': os.environ['CTRL_PROJECT'], 'files': files}))
else:
    print(os.environ['CTRL_PROJECT'] + ':\n' + '\n'.join(files))
PY
