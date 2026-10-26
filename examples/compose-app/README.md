# Docker Compose application

This is a self-contained fictional application, with a Dockerfile, sample content,
and Compose file. Local workflows need Docker with Compose v2. Building downloads
the public Python base image; no application dependencies are installed.

Inspect without Docker, a host, or credentials:

```bash
ctrl check
ctrl build api --tag review --dry-run
ctrl help rd --json
ctrl help rd --source
ctrl rd api --on prod --dry-run
```

## Run locally

From this example's directory, with ctrl installed:

```bash
ctrl build api --tag review --yes
ctrl start --tag review --yes
ctrl status
ctrl smoke
ctrl logs api --lines 20
ctrl stop --yes
```

The sample responds on http://127.0.0.1:8080/ and /health. Start uses the locally
built image and does not pull/build. Stop removes the example's containers/network;
it never deletes images or volumes. Keep this stack separate from real applications.
No APP_DIR or external repository is needed. Build writes a Docker image, not a
file in this directory. Logs and status use the supplied Compose implementations.

## Review remote operations

The prod target is a placeholder, not a real host. Its cwd is /srv/demo-app.
Replace VM_HOST and the deploy user with your own host/account, configure SSH keys
and known_hosts, provision the directory, and deliberately sync the required files.
The optional sync-config script uploads only docker-compose.yml, without secrets.

Remote deploy pulls images; example/api:review is a local sample image, not a
published registry image. Before remote deployment, choose your own repository,
build/push that image, and update Compose to reference it. The example does not
pretend that the local build automatically makes an image available on your VM.

`rd` aliases the supplied compose/redeploy operation: pull and recreate one service.
`restart` restarts without pulling. These choices are explicit in ctrl.yaml; your
project can replace them with other implementations. Remote operations must use
--on prod; local is always the default. Use plans before authorizing changes.

For the source-checkout invocation style and other project types, see ../README.md.
