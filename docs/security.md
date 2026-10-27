# Execution and audit boundaries

ctrl is a controlled operations interface, not an OS sandbox. It makes a reviewed
script discoverable, validates inputs, narrows inherited environment, and records
execution identity/results. An agent can still bypass ctrl if its shell tool has
broader permissions. Enforce actual access restrictions at the tool/OS/account
layer; do not present ctrl as a security boundary on its own.

## Before executing

- Project operations are enabled explicitly; no arbitrary shell snippets or eval.
  Library names are inspectable but cannot bypass project bindings for execution.
  The init bootstrap operation is always available to create configuration/scripts.
- Parameter names, types, choices, flags, and patterns are checked against contracts.
- Script paths and symlinks must remain inside the project.
- Only declared credentials are forwarded; dotenv files are parsed as literal data.
- Write/destructive operations require --yes or interactive confirmation.
- A start audit event must be durably written before execution is permitted.
- The reviewed body is snapshotted and hashed, alongside the effective contract.

Scripts, contracts, configuration, supplied assets, and the local Python/yq/Bash
executables are trusted code/data. Review changes to all of them. A contract cannot
prove effects, tool use, idempotence, or safe handling of file paths. Regex patterns
are trusted contract code and should be simple enough to avoid expensive matching.

## Audit

The project journal is .local/ctrl/audit.jsonl. Add .local/ to .gitignore. Events
share a UUID run_id: started, validated, executing, finished as applicable.
Validation failures and confirmation denials produce finished/rejected records.
Timeout returns 124; cancellation returns 130. Records include timestamp, version,
project, operator, operation, selected implementation, script/contract SHA256, effective configuration hash,
target, mode (run/check/plan), redacted parameters, effects, exit code, and duration.

Files are mode 0600. Appends use an advisory exclusive lock and fsync. An unwritable
journal prevents execution. SIGKILL, power loss, and disk failure can leave an
unmatched start/executing record; treat that as an unknown outcome. The journal is
local and editable by its owner, not tamper-evident or a centralized audit service.
Errors before a project can be loaded cannot be recorded in its journal.

Environment values and operation stdout/stderr are not recorded. Parameters marked
secret are redacted. Other parameter values are recorded: do not put secrets in
unmarked strings. Secret CLI arguments are visible in the original process argv;
prefer env declarations. Delegated operations include parent_run_id so copy relay legs can be traced to
the original copy request. Script output may itself expose secrets; ctrl cannot
sanitize arbitrary application output reliably.

Interactive SSH is explicitly marked destructive and needs consent. Audit covers
session start/end, target, and status; commands typed inside SSH are not captured.

## Remote transport

SSH key/agent authentication uses BatchMode. Explicit `password_env` targets use
local sshpass with a mode-0600 credential file in a private temporary directory;
the password is not put in argv or audit. The file is removed on completion,
failure, timeout, or handled cancellation. SIGKILL/power loss can leave temporary
files; the same local account can read its credentials. Host verification stays
strict by default with either authentication method.

Controller scripts receive explicitly configured password credential variables
for local delegation (such as copy relays). A local controller dispatcher can
receive credential variables declared by project targets. Treat controller
scripts as trusted code. Credentials are not forwarded to remote scripts unless
the script contract separately declares them. `ssh-key-setup` is an explicit write
operation: it grants access, preserves existing keys with a backup, verifies the
selected key, and never changes password-login policy or target configuration.
Target host, user, and port are validated. Parameters and environment travel as
quoted literals over SSH stdin, not interpolated expressions in the remote command.
Checks send only prerequisite probes. Plans make no SSH connection. Remote targets
need Bash and the operation's tools; not Python, yq, or ctrl.

SSH itself may read the user's SSH configuration or invoke configured ProxyCommand
helpers. Read-only operations can still open network connections and create audit
records. Timeout/cancellation kills the local SSH process; remote descendants are
not guaranteed to terminate after disconnect. Avoid detached remote jobs when the
operation contract assumes synchronous completion.
