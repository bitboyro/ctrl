# Configuration contract v1

Use `version: 1` for the configuration format. This is independent of the runner
release version. ctrl searches upward for ctrl.yaml, or accepts `--config PATH`.
Relative script paths, env files, local working directory, and the journal are
anchored to that file's directory. No automatic local override merge occurs.

```yaml
version: 1
project: my-app
env_files: [.local/secrets.env]  # explicit; literal KEY=value, never sourced
operations:
  status: compose/status
  deploy: compose/deploy
  redeploy:
    uses: compose/redeploy
    aliases: [rd]
  cp: host/copy
  backup:
    script: ./scripts/backup.sh
    environment:
      BACKUP_DIR: /srv/backups
    # Contract is scripts/backup.yaml (or an inline contract: mapping).
targets:
  prod:
    host: "${VM_HOST}"
    user: deploy
    port: 22
    key: "${SSH_KEY}"          # optional; otherwise use normal SSH key/agent auth
    cwd: /opt/my-app
    host_key_policy: "yes"    # default; prepopulate known_hosts
    environment:
      COMPOSE_FILE: docker-compose.yml
```

Only `version`, `project`, `env_files`, `operations`, and `targets` are accepted.
No project file is executable configuration. Legacy 0.4 fields produce a migration
error rather than silently choosing a target or dropping services.

## Implementations and aliases

A value like `compose/status` selects an implementation shipped with ctrl. A
value starting `./` selects a project .sh file with a matching .yaml contract.
Expanded entries accept exactly one of `uses` or `script`, optional `aliases`,
and optional `environment`. Project scripts can also use an inline `contract`.
Contracts of shipped implementations cannot be weakened with overrides: copy
the script into the project and declare its own contract instead.

Configured names and aliases must be unique plain tokens. Core names (`help`,
`run`, `check`, `upgrade`) are reserved. Enabled operation names/aliases take
precedence over documentation topics, so `ctrl help NAME` always shows their contract. There is no implicit scripts/ discovery,
plugin download, extension sourcing, or implementation autodetection. Qualified
names can be inspected with `ctrl help compose/status`; execution requires a
project binding. The project registry is the execution allowlist.

## Targets

Local is always `--on local` and is the default. There is no implicit production
target. Remote targets require a host; default user is root, port 22, cwd /tmp.
Password authentication is not supported: use SSH keys or ssh-agent. Host key
checking defaults to strict `yes`; `accept-new` is an explicit trust-on-first-use
opt-in. Do not set it to disable verification.

`--on staging,prod` executes sequentially, continues after individual failures,
and returns nonzero if any fails. The complete selection is checked for unknown
targets before execution. Each target receives its own audit trail. At most 32
explicit targets are accepted. Tags, implicit all-host selection, and parallel
fan-out are intentionally absent in v1.

`execution: target` streams the script to Bash on the selected host; the remote
working directory must already exist. Nothing is installed there. A local
operation rejects remote selection. A controller operation executes locally but
receives connection details for the selected remote target (SSH, copy, and sync).
Controller contracts with target_optional: true can also execute a local dispatcher.
File-copy endpoints such as prod:/path select targets explicitly; they do not
create an implicit production default.

## Environment

Env files contain literal KEY=value assignments; surrounding single/double quotes
are removed. There is no command substitution, variable expansion, or shell
execution in env files. Process environment takes precedence; earlier env files
win over later files. Missing explicitly listed files are errors.

`${NAME}` substitution is supported in operation environment and target connection
values. An unset referenced variable is an error when that operation/target is
used. Shell defaults such as `${NAME:-value}` are not supported.

Only contract `env` names and explicitly configured operation/target environment
are forwarded to scripts, plus a small system environment and documented CTRL_*
values. Target environment overrides operation environment. Runner/system names
and shell/Python loader variables cannot be overridden. Other parent secrets are
not inherited. Environment values are never included in help, plans, or audit.
