# How to release ctrl

ctrl is a multi-file Bash tool (`ctrl.sh` + `lib/*.sh` + `lib/tools.yaml` +
`bundled/*.sh` + `completions/`). At release time `build.sh` concatenates everything —
libs, the tool registry, every bundled script and the completions — into a single
self-contained `dist/ctrl`, published as a **GitHub Release asset** together with
`ctrl.sha256`. Users install it with `install.sh`, or upgrade with `ctrl upgrade`;
both verify the checksum.

A release is driven entirely by pushing a `vX.Y.Z` git tag — CI builds and publishes.

> Source of truth for the version is the `VERSION` file. The git tag must match it.

---

## 1. Pre-flight

- [ ] Working tree clean, on `main`, up to date with `origin/main`.
- [ ] `CHANGELOG.md` has an entry for the new version (Keep a Changelog format).
- [ ] `SKILL.md` / `README.md` updated if behaviour changed.
- [ ] Local build + smoke:
  ```bash
  bash build.sh                 # → dist/ctrl
  dist/ctrl --version           # prints the new version
  bats -r tests/                # unit, property, smoke, integration (SSH skips without sshd)
  shellcheck -S warning ctrl.sh build.sh install.sh lib/*.sh
  ctrl run lint                 # shellcheck (+ bundled/.shellcheckrc), YAML, workflows
  ```

## 2. Bump the version

Edit `VERSION` to the new `X.Y.Z` (no leading `v`). `build.sh` reads it and stamps
`CTRL_VERSION` into `dist/ctrl`.

```bash
# edit VERSION → X.Y.Z
git add VERSION CHANGELOG.md
git commit -m "release: vX.Y.Z"
git push origin main
```

## 3. Tag and push

The tag must be `v` + the contents of `VERSION` so the published binary and the
release tag agree.

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

## 4. What CI does (`.github/workflows/release.yml`)

On any `v*` tag push:

1. Runs the full **test** suite via `test.yml` — ShellCheck/shfmt lint, unit +
   property tests (bats, on ubuntu + macOS), `dist/ctrl` smoke tests, and SSH
   integration tests against an sshd service container.
2. Only if tests pass: runs `bash build.sh` to produce `dist/ctrl`, and writes
   `dist/ctrl.sha256`.
3. Uploads `dist/ctrl` and `dist/ctrl.sha256` as release assets via
   `softprops/action-gh-release` (auto-generated release notes).

A push to `main` (without a tag) runs `test.yml` only — no release.

## 5. Verify

```bash
# Release asset is live:
curl -sIL -o /dev/null -w '%{http_code}\n' \
  https://github.com/bitboyro/ctrl/releases/download/vX.Y.Z/ctrl        # → 200
curl -sIL -o /dev/null -w '%{http_code}\n' \
  https://github.com/bitboyro/ctrl/releases/download/vX.Y.Z/ctrl.sha256 # → 200

# Installer pulls the new version:
curl -fsSL https://raw.githubusercontent.com/bitboyro/ctrl/main/install.sh | bash -s -- vX.Y.Z
ctrl --version
```

---

## How users install

`install.sh` installs the latest (or a pinned) release binary into `~/.local/bin`
after SHA256 verification, and registers the Claude skill. `--main` installs the
source tree from the `main` branch archive instead (contributors).

```bash
# latest
curl -fsSL https://raw.githubusercontent.com/bitboyro/ctrl/main/install.sh | bash

# pin a version (and generate ctrl.yaml)
curl -fsSL https://raw.githubusercontent.com/bitboyro/ctrl/main/install.sh | bash -s -- vX.Y.Z --init
```

Requirements on the user's machine: `curl` and [`yq`](https://github.com/mikefarah/yq).

> ctrl has **no Homebrew formula** today. If you want a `brew install` path, mirror
> scanos: add a `Formula/ctrl.rb` pointing at the `dist/ctrl` release asset, publish
> it in a `bitboyro/homebrew-ctrl` (or shared `homebrew-tap`) repo, and extend
> `release.yml` to bump that formula on tag. See `scanos/HowToReleaseScanos.md`.

---

## Rollback

```bash
gh release delete vX.Y.Z --yes
git push origin :refs/tags/vX.Y.Z
git tag -d vX.Y.Z
```

Re-tag only after fixing `VERSION` and `CHANGELOG.md`.
