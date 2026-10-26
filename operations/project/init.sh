#!/usr/bin/env bash
set -euo pipefail
exec python3 - <<'PY'
import os
from pathlib import Path

root = Path(os.environ['CTRL_PROJECT_DIR'])
name = os.environ.get('CTRL_PARAM_SCRIPT', '')
if name:
    path = root / 'scripts' / f'{name}.sh'
    contract = path.with_suffix('.yaml')
    if path.exists() or contract.exists():
        raise SystemExit('Refusing to overwrite an existing script or contract')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('#!/usr/bin/env bash\nset -euo pipefail\nprintf \'Hello from %s\\n\' "$CTRL_OPERATION"\n')
    path.chmod(0o755)
    contract.write_text('version: 1\ndescription: Describe exactly what this operation does\neffects: read\nexecution: local\ntools: []\nenv: []\nparameters: []\n')
    print(f'Created {path.relative_to(root)} and {contract.relative_to(root)}')
    print(f'Enable it under operations: {name}: ./scripts/{name}.sh')
else:
    config = root / 'ctrl.yaml'
    if config.exists():
        raise SystemExit('Refusing to overwrite ctrl.yaml')
    # YAML-quote arbitrary directory names via JSON's compatible string syntax.
    import json
    config.write_text('version: 1\nproject: ' + json.dumps(root.name) + '\noperations:\n  status: compose/status\n  deploy: compose/deploy\n  logs: compose/logs\n')
    ignore = root / '.gitignore'
    text = ignore.read_text() if ignore.exists() else ''
    if '.local/' not in text.splitlines():
        ignore.write_text(text.rstrip() + '\n.local/\n')
    print('Created ctrl.yaml. Run ctrl help, then ctrl check.')
PY
