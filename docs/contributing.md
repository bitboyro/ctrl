# Contributing

## Architecture

src/ctrl.py is the standard-library runner. ctrl.sh is the source entry point.
operations/GROUP/NAME.sh is a standalone Bash implementation;
operations/GROUP/NAME.json is its canonical, validated contract. JSON avoids a
runtime YAML parse for each supplied contract. Project sidecars use YAML.

The same runner handles explicit run and shortcut dispatch, typed validation,
clean environments, local execution, SSH streaming, cancellation, and locked audit
appends. Docker/Compose/build knowledge lives in scripts, not core dispatch.
Controller operations share a JSON SSH argv primitive; they never eval it.

examples/catalog.json is the explicit public package allowlist and the source for
ctrl help examples. Add only fictional, self-contained projects. Every public
example needs a walkthrough, runnable artifacts, contracted scripts, and tests.
Do not add internal infrastructure customizations to public directories.

## Validation

```bash
python3 -m unittest discover -s tests/runner -v
shellcheck -S warning ctrl.sh build.sh install.sh operations/*/*.sh scripts/*.sh examples/*/scripts/*.sh completions/ctrl.bash
bash build.sh
./dist/ctrl --version
./dist/ctrl help scripts
```

The fast suite uses isolated projects, fake external tools, and real localhost
HTTP requests. The opt-in integration suite runs disposable local Docker/SSH
workloads. Neither suite contacts production or mutates sibling repositories. Tests cover source/package
parity, strict contracts, failed execution, literal secret handling, remote argument
quoting, clean environments, timeout/cancellation, confirmation, audit failure, upgrade rollback, and package privacy. HTTP lifecycle tests require
loopback permission; see tests/README.md for test layers and remaining gaps.

For real Docker/Compose/OpenSSH/rsync validation, run
`CTRL_REAL_INTEGRATION=1 python3 -m unittest discover -s tests/integration -v`
(or `./ctrl.sh test-integration --yes`). Docker must be local and loopback access
permitted. The separate Linux CI job gates releases on these tests. See
tests/README.md for fixture isolation, prerequisites, cleanup, and remaining gaps.

## Build and release

build.sh creates dist/ctrl, ctrl.sha256, a full versioned tarball and its SHA256.
The zipapp embeds the same operation manifests and docs as the source checkout.
Completions query machine-readable help rather than maintaining operation lists.

For a release: finish local checks, update VERSION and CHANGELOG, commit, then tag
vVERSION. Release CI checks tag/version agreement and runs the same tests on Linux
and macOS before publishing. Do not publish 0.5.0-dev as a final release.
See HowToReleaseCtrl.md for the short release procedure.
