#!/usr/bin/env bash
set -euo pipefail
cd "${CTRL_PROJECT_DIR}"
shellcheck -S warning ctrl.sh build.sh install.sh operations/*/*.sh scripts/*.sh examples/*/scripts/*.sh completions/ctrl.bash
python3 - <<'PY'
import ast
from pathlib import Path
for directory in ('src','scripts','tests/runner','tests/integration'):
    for path in Path(directory).glob('*.py'):
        ast.parse(path.read_text(), filename=str(path))
for path in Path('examples').rglob('*.py'):
    if '.local' not in path.parts:
        ast.parse(path.read_text(), filename=str(path))
print('ShellCheck and Python syntax: OK')
PY
