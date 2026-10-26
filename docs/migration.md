# Migration from ctrl 0.4

0.5.0 is a deliberate interface/configuration break. Keep a 0.4 executable available
until each project's workflows are reviewed and migrated. No automatic migration
runs and no production configuration is rewritten by upgrading ctrl.

## Mental model

Only help, run, check, upgrade are core. `ctrl NAME` and `ctrl run NAME` use the
same runner. Projects explicitly bind operations to supplied implementations or
reviewed .sh scripts with typed contracts. Builtins are not automatically enabled
(except init). Qualified names are inspectable with `ctrl help compose/status`; execution requires
a configured project operation, so library names cannot bypass the allowlist.

| 0.4 capability | 0.5 replacement |
|---|---|
| list/info/scripts discovery | ctrl / ctrl help --json |
| remote-status / rs | configure status: compose/status |
| remote-logs / rl | configure logs: compose/logs |
| deploy | configure deploy: compose/deploy (no build or sync) |
| redeploy / rd | configure redeploy: compose/redeploy; alias rd explicitly |
| ssh | configure ssh: host/ssh (session-level audit) |
| sync / cp | configure sync: host/sync (upload only in v1) |
| image/build/push/release | docker/build, or project build/release scripts |
| health-check / hc / diff | project operations with declared scope and output |
| init | supplied project/init operation (ctrl init) |
| doctor | ctrl check; install dependencies with normal package tools |
| history | read .local/ctrl/audit.jsonl with jq |
| set tag/default | edit project data explicitly; no implicit prod default |
| mcp | removed; agents use the same CLI and short skill |
| extensions / sourced hooks | explicit project operations |
| media/setup/network utility collection | removed; use standalone tools/scripts |
| completion command | package completions, dynamic discovery |

The old deploy --release/--sync combinations are not silently recreated. If a
project needs a combined delivery workflow, define and review that one operation.
A host restart is not an image rebuild: bind rd to the behavior your project wants
and document that choice in its contract.

## Configuration and scripts

Replace services/machines/deployments/meta/scripts with project, operations,
targets, optional env_files, and version: 1. Service/build-specific data belongs to
the selected implementation or Compose/project files; core does not interpret it.
See ctrl help config and the public project catalog (ctrl help examples).

Replace script-header metadata with a .yaml sidecar contract. Typed parameters
arrive in CTRL_PARAM_* environment variables. Explicitly declare environment and
prerequisites. No source access to ctrl internals; use CTRL_BIN and CTRL_CONFIG_FILE
for explicit local composition if necessary. Remote scripts are standalone.

Env files are no longer shell programs. Shell substitutions/commands inside .env
are literal strings. SSH passwords, automatic override merges, parallel/tag/all
fan-out, framework-specific build tool detection, and implicit secrets loading
are absent. SSH keys/agent auth and explicit targets replace those behaviors.
