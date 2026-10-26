# Service on a VM

This example shows remote operations whose implementation belongs to the project,
rather than to ctrl's core. All hosts, paths, accounts, and service names are fictional.

Inspect and plan without a server:

```bash
ctrl check
ctrl help restart --source
ctrl status --on demo --dry-run
ctrl restart --on demo --dry-run
```

To execute, supply your own host and configure SSH key/agent authentication,
known_hosts, the existing remote directory, and a deployed demo-web.service:

```bash
export DEMO_HOST=your-own-host.example.invalid
ctrl check status --on demo
ctrl status --on demo
ctrl restart --on demo --yes
```

Those last three commands contact your host. This example does not provision
accounts, create directories, deploy code, write sudo policy, or install units.
The illustrative demo-web.service.example shows how the Python example's built
archive could be hosted after you deliberately provision a VM.

The status script preserves systemctl's exit status: an inactive unit can produce
a nonzero result. Restart uses `sudo -n`, so missing privileges fail instead of
prompting/hanging. Configure narrowly scoped permissions for your own environment.
Both contracts permit only demo-web.service; another unit is rejected before SSH.
Both bodies refuse local execution, even if --yes was supplied.

No arbitrary remote command parameter is accepted. The optional SSH operation is
an explicit interactive escape hatch with destructive effects and session-level
rather than command-level audit. Don't enable it for agents that should only use
the constrained service operations.
