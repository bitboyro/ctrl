# ctrl backlog

Open items after the 0.4 work (2026-09-26). The 37 findings from the
2026-06-18 review are resolved except those listed here — see CHANGELOG
`[0.4.0]` → Security / Fixed for what changed.

---

## Open — security / correctness

- **`StrictHostKeyChecking=accept-new`** (`lib/core.sh` `_ssh_flags`, `lib/remote.sh`, `lib/cp.sh`): trust-on-first-use is MITM-able on the first connect. Proposal: `machines.hosts[].host_key` (pin a known_hosts line) or `CTRL_SSH_STRICT=yes` to require a pre-populated known_hosts; keep accept-new as the documented default.
- **`set -a` exports every env-file variable** (`lib/core.sh` `load_config`): secrets from `meta.env_files` / `.local/secrets.env` are visible to every child process. This is currently relied on — local scripts read them from the environment. Proposal: stop exporting, and export only the variables a script declares in `@env` / `@env-optional` (the remote path already forwards only those).
- **Extension namespace has no conflict check** (`ctrl.sh` extension dispatch): extensions now use `ctrl_ext_cmd_<name>`, but the legacy `ctrl_cmd_<name>` fallback and a missing load-time check mean an extension can still define a function that collides with an internal helper. Proposal: after loading, warn on any extension function that isn't `ctrl_ext_*`, and drop the legacy prefix in 0.5.
- **VERSION missing falls back silently to "unknown"** (`lib/core.sh:4`): runs before logging exists; warn once from `ctrl check`/`doctor` instead.

## Not yet verified outside this machine

- **`run --on` over real SSH**: covered by `tests/integration/test_ssh.bats` (3 new tests) against the CI sshd container, but skipped locally — first real confirmation is the next CI run. Remote hosts need `bash` (`bash -s`); the linuxserver/openssh-server image is expected to ship it.
- **Setup scripts on real distros** (`install-docker`, `add-swap`, `harden-ssh`, `ufw-basics`, `install-tailscale`, `gitlab-runner`): dry-run tested with simulated `CTRL_OS`/`CTRL_DISTRO`; run each once on a throwaway Debian/Ubuntu and Fedora VM before announcing them (`ctrl run <name> --on <vm> --yes`).
- **Desktop scripts** (`rec`, `snap`, `share --tunnel`): command construction is tested; actual capture needs a screen-recording permission / display and was not exercised. Try `ctrl run rec --time 3` on macOS and an X11/Wayland box.
- **`ctrl upgrade` / `install.sh`**: tested against a fake GitHub (`tests/smoke/test_upgrade_install.bats`); the first real run is the 0.4.0 release, which is also the first to publish `ctrl.sha256`.

## Feature gaps

- **`ctrl secrets`**: list every env var the project expects — `${VAR}` references in `ctrl.yaml` (doctor already scans these) plus `@env` of every project script — with set/unset status. Could be `ctrl doctor --env`.
- **Remote OS/arch cache**: `--on` pre-flight asks each host every time; cache `uname -sm` per machine in `.local/` if fan-out to many hosts gets slow.
- **`list deployments`** for completions of `--on` (today completion offers machines, `local`, `all`).
- **More library ideas**: `backup-volume` (docker volume → tarball, `--on`), `logs-grep` across hosts, `bench` (disk/network), `pg-dump` for compose postgres.
