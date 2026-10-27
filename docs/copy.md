# File copy is an operation

Enable the supplied implementation in ctrl.yaml:

```yaml
operations:
  cp: host/copy
```

`ctrl cp` and `ctrl run cp` use the same runner, validation, confirmation, and audit.
This is separate from host/sync: copy can read or write a remote target; sync is
rsync upload/mirroring with an explicit deletion option.

```bash
ctrl cp ./file ./copy --yes
ctrl cp ./file prod:/srv/app/file --yes
ctrl cp prod:/var/log/app.log ./app.log --yes
ctrl cp staging:/srv/report.csv prod:/srv/report.csv --yes
ctrl cp ./folder prod:/srv/app/ --recursive --yes
```

Equivalent explicit-target forms:

```bash
ctrl cp ./file /srv/app/file --on prod --yes
ctrl cp /var/log/app.log ./app.log --on prod --download --yes
```

Do not mix endpoint names with --on. Names must be declared in targets; both ends
are checked before a relay begins. Relative local paths are relative to the project;
relative remote paths use the selected target cwd. Prefer explicit absolute remote
paths. Remote globs, newlines, and ~ expansion are not accepted. Prefix a local name
containing a colon with ./ to distinguish it from target:/path.

Copies may overwrite destination files. Directories require --recursive and use
copy/SCP directory semantics; they do not mirror or delete extra destination files.
Times/mode are preserved by default where permitted; use --preserve=false to opt out.
For rsync trailing-slash/mirroring behavior, use a separate sync operation.

Remote copies require an OpenSSH scp client with SFTP support and an enabled SFTP
subsystem on the SSH server. No remote ctrl, Python, or rsync is required. SFTP is
forced so file names are data, not remote shell expressions. Host/user/port/key and
strict host-key policy are resolved through the runner's shared connection settings.
It works with stock modern macOS SSH tools without replacing system rsync.

Target-to-target copy downloads into a private local temporary directory and then
uploads using the destination target's credentials. The hosts do not need to trust
or reach one another. The relay is removed on success or failure. Data traverses
this controller; prefer a project-specific transfer operation for very large data.

An endpoint-style plan describes the local dispatcher and its explicit endpoint
parameters without connecting. Use --on TARGET for a fully resolved one-target plan.
Each actual transfer is audited separately and linked to its parent request; no
file contents are recorded. A failed leg returns nonzero to the original command.
