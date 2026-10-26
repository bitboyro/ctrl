# Node.js application

A working HTTP app using Node's built-in modules, with no npm dependencies.
Install Node.js separately; ctrl checks for the node executable before use.

From this directory, with ctrl installed:

```bash
ctrl check
ctrl test
ctrl build --yes
ctrl start --port 3000 --dry-run
ctrl start --port 3000 --yes
```

Start serves `http://127.0.0.1:3000/` and `/health` in the foreground. Ctrl-C stops
it, and the contract limits a session to one hour. Only 3000/3001 are accepted.

Test executes assertions without opening a port. Build simply prepares
`.local/build/app.js` and package.json; it does not claim to compile or bundle code.
For a real npm project, put dependency installation, lint/test/build commands, and
required environment in its reviewed scripts/contracts. Avoid implicitly running
npm install just because a Node project was detected.

These operation names match the Python example even though their implementations
are different. No remote deployment or registry publication is configured.
