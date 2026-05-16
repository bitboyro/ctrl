# ctrl test suite

Bats-core based, organized by speed and runtime requirements.

| Tier | Path | What | Needs |
|------|------|------|-------|
| Unit | `tests/unit/` | Pure functions, YAML parsing, config loading | bats, yq, jq |
| Property | `tests/property/` | Randomized inputs over the same surface | bats, yq, jq |
| Smoke | `tests/smoke/` | Built `dist/ctrl` as a user would install it | bats, yq, jq |
| Integration | `tests/integration/` | Real SSH/MCP/journal round-trips | bats, yq, jq, sshpass, reachable sshd |

## Prerequisites

```bash
brew install bats-core yq jq sshpass    # macOS
# Ubuntu: apt-get install bats jq sshpass + install yq v4 from GitHub releases
```

## Run

```bash
# Fast feedback (no SSH/Docker needed) — ~6s locally
bats tests/unit/

# Property tests — ~10s locally with the default 25 iterations
bats tests/property/

# More iterations for confidence
PROPERTY_ITERATIONS=100 bats tests/property/

# dist/ctrl smoke (rebuilds dist/ first)
bats tests/smoke/

# Everything except SSH (MCP + journal integration only)
bats tests/integration/test_mcp.bats tests/integration/test_journal.bats
```

## Integration tests against a real sshd

The SSH and SCP integration tests skip themselves unless an sshd is reachable
at `${TEST_SSH_HOST:-127.0.0.1}:${TEST_SSH_PORT:-2222}` with credentials
`${TEST_SSH_USER:-ctrltest}` / `${TEST_SSH_PASSWORD:-ctrltest}`.

To run them locally, start the same container CI uses:

```bash
docker run -d --name ctrl-test-sshd \
  -p 2222:2222 \
  -e PASSWORD_ACCESS=true \
  -e USER_NAME=ctrltest \
  -e USER_PASSWORD=ctrltest \
  -e SUDO_ACCESS=true \
  -e PUID=1000 -e PGID=1000 \
  lscr.io/linuxserver/openssh-server:latest

# wait a few seconds for sshd to come up, then:
bats tests/integration/

# cleanup
docker rm -f ctrl-test-sshd
```

## CI

`.github/workflows/test.yml` runs five jobs on every push and PR:

1. **lint** — ShellCheck + shfmt (advisory).
2. **unit** — matrix across `ubuntu-latest` and `macos-latest`.
3. **property** — Ubuntu only, `PROPERTY_ITERATIONS=50`.
4. **smoke-dist** — builds `dist/ctrl`, runs smoke suite against it, uploads the binary as an artifact.
5. **integration** — Ubuntu only, with `linuxserver/openssh-server` as a service container.

The release workflow (`.github/workflows/release.yml`) calls this workflow as a
reusable check before tagging — releases cannot ship without a green test run.

## Test conventions

- Every test file begins with a comment referencing the design-doc property it
  validates (e.g. `# Feature: ctrl-devkit-integration, Property 7: ...`).
- Tests use the `setup_test_dir` / `teardown_test_dir` helpers in
  `tests/helpers/setup.bash` to get a fresh tmp dir + isolated `CTRL_CONFIG`.
- `write_fixture_yaml` generates a minimal valid `ctrl.yaml`; per-test
  customization is done via `FIXTURE_*` env vars or `yq -i` patches.
- `run_ctrl` invokes the in-tree `ctrl.sh` against the current fixture.
- Property tests randomize via helpers in `tests/helpers/random.bash`; default
  iteration count is 25 (override with `PROPERTY_ITERATIONS=N`).

## Adding new tests

For a new pure function or YAML parser change, add a unit test in
`tests/unit/`. For a new user-facing flag or command, also add a smoke test in
`tests/smoke/` so the bundled `dist/ctrl` is exercised. For a behavior that
should hold across all valid inputs, add a property test.

## Known gaps

- No `ctrl deploy` integration test (would need a full docker compose
  round-trip against an sshd-with-docker container; defer until needed).
- No shfmt enforcement — currently advisory until a project style is agreed.
