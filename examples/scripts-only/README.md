# Scripts-only project

This is the smallest example. It needs the normal ctrl requirements and no extra
tools. `report` is a project-selected Bash script with a typed format parameter.

From this directory, with ctrl installed:

```bash
ctrl
ctrl check
ctrl report --help
ctrl help report --source
ctrl report --format json
ctrl run report --format text
```

The two invocation styles share one runner. `--format xml` fails before the script
executes because the contract allows only text/json. Parameters arrive as
CTRL_PARAM_FORMAT, not arbitrary shell arguments. The script uses CTRL_PROJECT_DIR
rather than guessing where ctrl is installed. There are no targets or credentials.

The operation reads the top-level file names and prints a report. Its only writes
are ctrl's audit events in `.local/ctrl/audit.jsonl`; inspect that file to see its
identity, redacted parameters, and result. To add another operation, create its
script and sidecar contract and enable it explicitly in ctrl.yaml.
