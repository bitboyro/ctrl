# Tests

Run `python3 -m unittest discover -s tests/runner -v` with Python 3.9+, Bash,
and mikefarah yq v4. The fast suite needs no Python packages, Bats, Docker daemon, or SSH server.
Node.js and JDK 17+ exercise their examples when installed; CI provisions both.
Maven commands, Compose, and systemd/SSH transport are verified with fake tools.

## What each layer proves

- `test_runner.py`: public CLI contracts, input rejection, environment filtering,
  confirmations, remote quoting, output/exit behavior, audit, installer/upgrader,
  completions, and source/package parity.
- `test_examples.py`: every public example's metadata and first workflow, actual
  Python/Node/JDK tests and local artifacts, plus container/VM command construction.
- `test_resilience.py`: disk/flush failure injection, source changes during a run,
  process-tree cleanup, rejected confirmation, interrupted/failed upgrade rollback,
  relocation, failed remote preflight, and operation/help-name collisions.
- `test_distribution.py`: private-file symlinks, env-file variants, invalid catalogs,
  checksum consistency, and preservation of previous artifacts after validation failure.
- `test_http_lifecycle.py`: real Python/Node HTTP requests over 127.0.0.1, occupied-port
  failures, cancellation, socket cleanup, and resulting audit outcomes. These use
  ephemeral ports and temporary projects, never an external host.

The HTTP tests require loopback socket permission. A restricted local sandbox may
skip that class; run the same suite outside that sandbox to exercise it. In CI,
blocked loopback is an error. A Docker daemon and external network are not needed.

## Real Docker / SSH integration (opt-in)

```bash
CTRL_REAL_INTEGRATION=1 python3 -m unittest discover -s tests/integration -v
# Equivalent project operation, with declared write effects:
./ctrl.sh test-integration --yes
```

Requires a local unix-socket Docker context, a running daemon, Compose, SSH and
ssh-keygen on the controller, and normal ctrl requirements. Public fixture image
and package downloads require network access on the first build. A sandbox must
permit Docker socket access and loopback connections. The separate Linux CI job
runs this suite after the fast Linux/macOS jobs; opting in with missing prerequisites
fails rather than silently skipping.

The real suite covers:

- Actual Docker image build and failure status/audit.
- Compose start, HTTP health request, status/logs, and stop/removal.
- Actual OpenSSH key authentication, quoted script/parameter streaming, declared
  environment, remote failure status, and missing-tool preflight.
- Strict host-key mismatch rejection and nonexecuting plan/check behavior.
- Actual rsync 3 transfers of binary files with quoted/spaced paths, preserving
  destination files by default and removing them only with explicit --delete.

A disposable SSH container provides both the server and an isolated Linux rsync 3
client. This avoids replacing macOS's system rsync or modifying user SSH files.
The tests pin the server key in temporary known_hosts files and use newly generated
client keys; the user SSH agent is disabled for these connections. They never mount the host Docker socket into containers, use privileged
containers, push images, prune Docker globally, or read production configuration.
Only 127.0.0.1 ports are published. The Docker context must be local; remote contexts
are refused before resources are created.

Cleanup verifies removal of test-owned containers, networks, and uniquely tagged
images. Fixture resources carry a run label, and ownership is checked before
removal. Cleanup failures fail the suite rather than being silently ignored.
Public base images and shared build cache may remain; no global prune is performed.
Build/server diagnostics are retained under ignored .local/integration/RUN_ID.
Abruptly killing the test process can interrupt cleanup; use its unique resource
names in the diagnostics rather than removing unrelated Docker resources.

## Isolation and limits

Tests build dist/ctrl and use isolated temporary projects and credentials. None
contact production or mutate sibling repositories. Audit records and generated
artifacts must remain inside fixtures or the source checkout's ignored .local/dist.

The fast suite uses fake tools; the opt-in suite establishes actual local Docker,
Compose, OpenSSH, and rsync interoperability. Real systemd, remote Docker deployment
on a VM, registry publication, and online Maven builds remain outside this suite. The journal is local and mutable,
not tamper-evident. Process-tree cleanup covers descendants in the operation's
process group; a deliberately detached process needs a separate job manager.

0.4's command/MCP/header-specific tests are replaced by the new operation contract.
The old interface is intentionally incompatible; see docs/migration.md.
