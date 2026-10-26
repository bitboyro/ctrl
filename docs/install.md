# Installation and updates

ctrl 0.5.0 is a breaking upgrade. Existing 0.3/0.4 configuration is not compatible.
Keep the previous executable for unmigrated projects; see ctrl help migration.
The installer does not convert configuration or rewrite scripts.

## Requirements

Linux/macOS with Python 3.9+ on the controller, Bash 3.2+, and mikefarah yq v4. No Python packages
are required. Operation prerequisites (Docker, SSH, rsync, etc.) are declared
individually. Supplied host/sync and the Compose sync-config example require rsync
3+ for protected remote arguments; macOS system rsync 2.6 is insufficient. Select
a separately installed rsync 3 on PATH for those operations. Remote operation targets need Bash and their declared tools.

## Local development package

```bash
bash build.sh
./install.sh --from ./dist
```

Default destination is ~/.local/bin/ctrl; override with CTRL_BIN_DIR. The installer
requires the matching ctrl.sha256, verifies SHA256 and the executable's version,
and atomically replaces the executable. It does not modify shell profiles,
project configuration, or agent settings.

To install from the extracted full archive instead, run `./install.sh --from .`
in its top-level ctrl-VERSION directory. The installer uses its local executable
and checksum, with no network access.

To keep an older installation working while reviewing the migration, install to
a separate versioned directory instead of replacing the command on PATH:

```bash
CTRL_BIN_DIR="$HOME/.local/share/ctrl/0.5.0/bin" ./install.sh v0.5.0
```

Invoke that directory's ctrl explicitly until the relevant project has migrated.
Do not point an old project at 0.5 merely by changing its version field: the
configuration and operation contracts need conversion.

## What is installed

The executable is a Python zipapp: it contains the runner, operation scripts and
JSON contracts, offline Markdown references, and the agent skill. These are read
from the same artifact/version. It can be copied to another machine with the
requirements installed. `ctrl help --all` inventories supplied operations.

The full ctrl-VERSION.tar.gz additionally contains readable docs, operation sources,
completions, installer, the public project examples, README, and skill. Its own SHA256 file
verifies the archive. Builds reject symlinks in distributed sources and exclude
local journals, caches, and .env variants. Validation failure preserves previous
local artifacts rather than publishing a partial package. Extract it for review or copy the skill to your agent's
normal skill directory, or extract it with `ctrl help agent`; registration is
explicit, not automatic or Claude-only.

To install the published release: `./install.sh v0.5.0`. Omitting the version selects
latest; checksums are mandatory. Downloading an executable directly without its
checksum bypasses verification and is not the recommended installation path.

## Updates

`ctrl upgrade --yes` downloads the latest executable and checksum from the official
repository, verifies it, sanity-checks the version command, and replaces the current
packaged executable atomically. It rejects source checkouts. To pin a version,
rerun the installer with that release tag. Project contracts use version: 1 and
are independent of runner versions.

## Completion

Source completions/ctrl.bash or put completions/ctrl.zsh in your Zsh fpath as _ctrl.
Candidates come from ctrl help --json, not a separately maintained operation list.
Shell completion installation is manual and optional.
