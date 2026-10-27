# Writing an operation

An operation is a standalone Bash script plus a YAML contract. It does not source
ctrl internals or need ctrl installed on the remote host. Create a starter:

```bash
ctrl init --script backup --yes
```

Then enable it in ctrl.yaml: `operations: {backup: ./scripts/backup.sh}`.

`scripts/backup.yaml`:

```yaml
version: 1
description: Dump one database into a local backup file
effects: write
execution: local
timeout: 300
tools: [pg_dump]
env: [DATABASE_URL]
parameters:
  - name: output
    flag: --output
    type: string
    default: backup.sql
    description: Output file relative to the project
```

`scripts/backup.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
pg_dump --dbname="$DATABASE_URL" --file="$CTRL_PARAM_OUTPUT"
```

Declare only parameters actually used by the implementation. ctrl never
appends user text to a shell command. All validated parameter values arrive as
`CTRL_PARAM_<UPPERCASE_NAME>` environment variables, not positional arguments.
Always quote expansions; use arrays for commands. Exit nonzero on failure.
Noninteractive operations receive empty stdin locally; remote stdin carries the
script. Arbitrary caller stdin streaming is not part of contract v1.

## Required contract fields

- `version: 1`: contract format, independent of the ctrl release version.
- `description`: concise, specific effects and scope.
- `effects`: `read`, `write`, or `destructive`. Write/destructive execution requires
  confirmation or `--yes`; this declaration is reviewed metadata, not proof.
- `execution`: `local`, `target`, or `controller`.

Optional fields: `tools` (executable names), `env` (required environment names),
`timeout` (positive seconds, default 300), `parameters` (default empty), and
`interactive` (boolean, default false; controller operations only), and
`target_optional` (boolean, default false; controller operations only). The latter
lets an operation such as file copy run locally or delegate to explicit endpoints.
Unknown fields are rejected. Local and remote prerequisites are checked before
execution. `ctrl check <operation>` never executes the operation body.

## Parameters

Each parameter has a unique lowercase `name` and `type`:

| Type | Accepted values |
|---|---|
| string | A string up to 4096 characters without NUL |
| token | Letters/digits followed by letters, digits, underscore, dot, hyphen |
| integer | A nonnegative integer |
| boolean | true/false; a flag without a value means true |
| enum | One of the declared string `choices` |

Without `flag`, a parameter is positional. With `flag: --name`, it is a named
option. Optional fields: `required`, typed `default`, `description`, `secret`,
`choices` (required for enum), and `pattern` (full-match regular expression for
string values). Required positionals precede optional ones. Boolean parameters
must be flags. Duplicate parameters/options are rejected. No arbitrary trailing
arguments or unknown flags are accepted, including after `--`.

```yaml
- name: service
  type: enum
  choices: [api, web]
  required: true
- name: force
  flag: --force
  type: boolean
- name: api_key
  flag: --api-key
  type: string
  secret: true
```

Prefer required environment for secrets: a secret CLI value can still be visible
in the caller's process listing. `secret: true` redacts values from plans and audit;
it does not hide the original invocation from the operating system. Secret
parameters cannot have stored defaults; declare required env instead.

Runner flags: `--on NAME[,NAME]`, `--yes`, `--dry-run`, `--config PATH`, and `--help`.
`--json` supports discovery/help, check, and plans. Flags are the same for shortcuts
and `ctrl run`. After `--`, tokens are interpreted only by the operation's contract.
Runner flag names cannot be redefined by operations.

## Dry-run, execution, and output

`--dry-run` prints a redacted execution plan with script/contract hashes, selected
target, effects, working directory, and prerequisites. It never runs a script,
executes SSH, or confirms remote availability. It writes audit records. It is not
a simulated Docker/SSH command transcript; use check for prerequisites.

Execution snapshots the script body before hashing/running it. stdout/stderr pass
through; the operation owns its output format. No logs/output are copied to audit.
Timeout is per operation/target (default 300 seconds), exit 124. Cancellation kills
the process group for noninteractive operations and records cancellation.

## Execution environment and remote behavior

All executions receive CTRL_VERSION, CTRL_PROJECT, CTRL_OPERATION, CTRL_TARGET, CTRL_RUN_ID,
CTRL_PROJECT_DIR (working directory), CTRL_REMOTE (0/1), CTRL_YES (0/1), and
CTRL_PARAM_* for supplied/defaulted parameters. Optional parameters with no default
are absent. Boolean defaults are false; integers use decimal strings.

Local/controller operations also receive CTRL_BIN and CTRL_CONFIG_FILE. Remote
operations do not receive local filesystem paths. No libraries, local files, or
project tree are implicitly uploaded: transferred scripts must be self-contained.

Controller operations receive CTRL_SSH_ARGS (a JSON argv array) and CTRL_TARGET_CWD.
This is the connection primitive used by supplied SSH/sync operations; consume it
with a JSON parser and subprocess argv, never eval. Target operations use the
runner's SSH transport automatically. See operations/host for runnable examples.

The local system environment allowlist is PATH, HOME, USER, LOGNAME, LANG, LC_ALL,
TERM, TMPDIR, SSH_AUTH_SOCK. Remote execution starts with a fixed system PATH and
remote HOME. Only declared operation environment and CTRL_* values are added.

## Review and validation

Read the body with `ctrl help NAME --source`, and the contract with
`ctrl help NAME --json`. The same source is accessible from the installed package.
Use ctrl check and
ShellCheck. Review paths, effects, credential use, and all executed subprocesses.
A read label or valid contract does not restrict what a malicious Bash body can do.
