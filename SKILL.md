---
name: ctrl
description: Discover, validate, author, and execute a project's contracted ctrl operations, locally or over SSH.
---

# ctrl operations

Use the project's selected operation rather than assuming what deploy/restart means.

1. Run `ctrl help --json` to discover enabled operations and aliases.
2. Read `ctrl help NAME --json` for the actual implementation, effects, typed
   parameters, environment requirements, and script/contract hashes.
3. Read `ctrl help NAME --source` to inspect the selected script. For changes,
   use `ctrl NAME ... --dry-run` to review the
   selected target and parameters. `ctrl check NAME ...` checks prerequisites.
4. Execute within the user's authorized scope. `--yes` acknowledges declared
   write/destructive effects; it does not grant authorization by itself.
5. Preserve failures. Use `.local/ctrl/audit.jsonl` to inspect the run's result.

`ctrl NAME` and `ctrl run NAME` use the same runner. Production targets are explicit
with `--on NAME`. Do not infer a target from an old 0.4 configuration.

To author an operation: `ctrl help scripts` is the complete contract reference;
`ctrl init --script NAME --yes` creates a starter. Declare parameters, effects,
tools, required env, execution mode, and timeout; enable the operation explicitly.
Use `ctrl help config` for target/environment configuration and `ctrl check` after
editing contracts. Keep project-specific behavior in scripts, not runner changes.

ctrl is not a Bash sandbox. Read/destructive labels are declarations; review code.
An unrestricted shell tool can bypass ctrl. Never place credentials in unmarked
parameters or operation output; prefer declared env. See `ctrl help security` for
audit and remote-execution limits, and `ctrl help migration` for 0.4 changes.
