# ctrl

**Discover, check, and run well-defined project operations.** Humans and agents use
one interface; projects choose the implementations.

```bash
ctrl                          # operations available in this project
ctrl deploy --help            # implementation, effects, typed parameters
ctrl help deploy --source      # exact selected Bash body
ctrl check deploy api --on prod
ctrl deploy api --on prod --dry-run
ctrl deploy api --on prod --yes
```

`ctrl deploy` is a shortcut for `ctrl run deploy`. Build, status, SSH, sync, logs,
and your own tasks are operations—not special branches of the CLI.

## Install and package

Linux/macOS; requires Python **3.9+**, Bash **3.2+**, and **mikefarah yq v4**. SSH and rsync are
needed only by operations that use them. Operation tools are checked before use.

**0.5 is a breaking upgrade.** Existing 0.3/0.4 project configuration must be
migrated before replacing a working installation. Keep the previous executable
for projects that have not migrated; see [migration](docs/migration.md).

Download the [0.5.1 release package](https://github.com/bitboyro/ctrl/releases/tag/v0.5.1),
extract it, and run `./install.sh --from .` to verify and install its executable.

From a source checkout:

```bash
bash build.sh
./dist/ctrl --version
./install.sh --from ./dist
```

`dist/ctrl` is an executable Python zipapp containing the runner, first-party
Bash operations, their contracts, offline docs, and agent skill. The full
`dist/ctrl-<version>.tar.gz` also includes readable sources, completions, docs,
and the public project examples. Both artifacts have SHA256 files.
Operation implementations are bundled rather than fetched at runtime. No dependency manager or MCP
server is required. See [installation and updates](docs/install.md).

## Start a project

```bash
ctrl init --yes
ctrl check
ctrl status --help
```

```yaml
version: 1
project: my-app
operations:
  status: compose/status
  deploy: compose/deploy
  logs: compose/logs
  backup: ./scripts/backup.sh
```

A project script has a small YAML contract alongside it. `ctrl init --script
backup --yes` creates both. Enable it explicitly in `operations`.

## Four core commands

| Command | Purpose |
|---|---|
| `help [operation or topic]` | Discover operations and read offline help |
| `run <operation> [parameters]` | Execute the selected implementation |
| `check [operation [parameters]]` | Validate project contracts or check execution prerequisites |
| `upgrade --yes` | Verify and atomically update an installed release |

`--version` prints the runner version. `ctrl help --all` lists available supplied
implementations. Only operations enabled by the project appear in normal help;
`init` is available to bootstrap an empty project.

SSH and file transfer remain available as operations: bind `ssh: host/ssh`,
`cp: host/copy`, and `sync: host/sync` as needed. Copy supports both directions:

```bash
ctrl cp ./file prod:/srv/app/file --yes
ctrl cp prod:/var/log/app.log ./app.log --yes
ctrl cp staging:/srv/report.csv prod:/srv/report.csv --yes
```

Use `--recursive` for directories. Copy uses literal paths and SFTP; use sync for
rsync mirroring/exclusions. [File-copy contract](docs/copy.md).

## Contracts and audit

Contracts declare effects, typed parameters, tools, required environment,
execution location, and timeout. Unknown flags, missing arguments, invalid
values, and unavailable prerequisites fail before the operation body executes.
Write/destructive operations require confirmation or `--yes`.

Every operation invocation creates start and finish records in
`.local/ctrl/audit.jsonl`, plus validation/execution events when reached. Records
identify the implementation, script and contract hashes, target, redacted
parameters, exit status, and duration. An unwritable journal blocks execution.

**This is controlled execution, not a Bash sandbox.** Scripts retain the operating
system permissions of the account running them. Review implementations before
allowing an agent to use them. [Security and audit limits](docs/security.md).

## Documentation

- [Configuration](docs/config.md): operations, aliases, targets, environment.
- [Writing operations](docs/scripts.md): the complete script/parameter contract.
- [Project examples](examples/README.md): scripts only, Python, Node.js, Java/Maven, Docker
  Compose, and a systemd service on a VM. All use fictional applications.
- [Migration from 0.4](docs/migration.md): removed concepts and replacements.
- [Contributing](docs/contributing.md): architecture, testing, build, release.
- [Agent skill](SKILL.md): a short operating workflow.

The executable serves these same references with `ctrl help config`, `ctrl help
scripts`, `ctrl help security`, `ctrl help install`, and `ctrl help migration`, `ctrl help agent`, and `ctrl help examples`.
Operation help comes directly from the validated contract.
