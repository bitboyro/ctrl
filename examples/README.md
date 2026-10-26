# Choose an example

All examples use fictional applications, placeholder hosts, and committed sample
code. Internal infrastructure customizations do not belong here. The reviewed
[catalog](catalog.json) is the release package allowlist; undeclared directories
are not packaged.

| Project type | Start here | What to learn |
|---|---|---|
| [Scripts only](scripts-only/README.md) | `ctrl report --format json` | The minimal contract, parameters, help, and audit |
| [Python application](python-app/README.md) | `ctrl test` | Test/build/start without a framework or pip dependencies |
| [Node.js application](node-app/README.md) | `ctrl test` | The same workflow around a different language/toolchain |
| [Java / Maven](java-maven/README.md) | `ctrl test --dry-run` | Project-specific build commands and explicit artifact/cache writes |
| [Docker Compose](compose-app/README.md) | `ctrl build api --tag review --dry-run` | Build/start/health and explicit remote deployment |
| [systemd service](systemd-service/README.md) | `ctrl status --on demo --dry-run` | Remote scripts, unit allowlists, SSH, and sudo boundaries |

## Try an example

After installing ctrl, change into that example's directory, then run `ctrl` and
`ctrl check`. Use `ctrl help OPERATION --source` to read the selected implementation
and `ctrl help OPERATION --json` to inspect its typed contract. Follow that example's
README for commands that execute anything.

From a source checkout, the same commands can be run from the repository root:

```bash
./ctrl.sh --config examples/scripts-only/ctrl.yaml report --format json
./ctrl.sh --config examples/python-app/ctrl.yaml test
./ctrl.sh --config examples/systemd-service/ctrl.yaml status --on demo --dry-run
```

The full release archive contains these example directories. `ctrl help examples`
serves the same catalog offline in the executable. Nothing is installed or deployed
by selecting an example. All operation invocations, including plans and checks,
write local audit records; `.local/` is excluded from source and distributions.

## Common conventions

The user-facing verbs stay familiar; every operation is backed by a selected script
and contract. Tests are read-only unless explicitly described otherwise. Build/start
operations declare writes, need --yes or confirmation, and explain their outputs.
Local start binds only to 127.0.0.1 and runs in the foreground; Ctrl-C stops it.
Remote plans need no connection, credentials, or remote tools. Actual remote
execution requires your own explicit host configuration and known_hosts setup.

Examples are small teaching projects, not production templates. Review and adapt
health behavior, service accounts, deployment strategy, paths, and secrets handling
before using them for real systems.
