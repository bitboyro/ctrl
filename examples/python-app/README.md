# Python application

A working standard-library HTTP app with test/build/start operations. No pip
packages or database are needed. It demonstrates project-owned build behavior;
ctrl does not need to know Python packaging rules.

From this directory, with ctrl installed:

```bash
ctrl check
ctrl test
ctrl build --dry-run
ctrl build --yes
ctrl start --port 8080 --yes
```

The final command serves `http://127.0.0.1:8080/` and `/health` in the foreground.
Ctrl-C stops it; the contract also limits a session to one hour. In another terminal,
open either URL. Only ports 8080/8081 are allowed by this example's contract.

Build writes `.local/build/demo.pyz`. It can also be run directly with
`python3 .local/build/demo.pyz --port 8080`; direct execution bypasses ctrl's audit.
Tests exercise the app's greeting function without opening a port or writing bytecode.

No remote target or deployment is implied. To deploy this application, add an
explicit operation matching your hosting environment; the systemd example shows
one possible VM approach. Inspect script bodies and contracts before adaptation.
