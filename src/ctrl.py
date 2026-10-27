#!/usr/bin/env python3
"""ctrl: contracted operations, local and remote. Python standard library only."""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
import zipfile

ROOT = Path(__file__).resolve().parent.parent
ARCHIVE = Path(sys.argv[0]).resolve()
PACKAGED = zipfile.is_zipfile(ARCHIVE)
VERSION = "0.5.0-dev"
if not PACKAGED:
    VERSION = (ROOT / "VERSION").read_text().strip()
RESERVED = {"help", "run", "check", "upgrade"}
NAME = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*\Z")
ENV_NAME = re.compile(r"[A-Z_][A-Z0-9_]*\Z")
UNSAFE_ENV = {"BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "PYTHONPATH", "PYTHONHOME", "LD_PRELOAD", "LD_LIBRARY_PATH"}
BASE_ENV = {"PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TERM", "TMPDIR", "SSH_AUTH_SOCK"}
RUNNER_FLAGS = {"--on", "--yes", "--dry-run", "--config", "--json", "--help", "--all", "--source"}


class Error(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Error(message)


def asset(name):
    if PACKAGED:
        with zipfile.ZipFile(ARCHIVE) as archive:
            return archive.read(name).decode()
    return (ROOT / name).read_text()


def assets(prefix, suffix):
    if PACKAGED:
        with zipfile.ZipFile(ARCHIVE) as archive:
            return sorted(n for n in archive.namelist() if n.startswith(prefix) and n.endswith(suffix))
    return sorted(str(p.relative_to(ROOT)) for p in (ROOT / prefix).rglob("*" + suffix))


def yaml_read(text):
    require(shutil.which("yq"), "mikefarah yq v4 is required; install it, then retry (ctrl help works without it)")
    result = subprocess.run(["yq", "-o=json", ".", "-"], input=text, text=True, capture_output=True)
    require(result.returncode == 0, "Invalid YAML (check syntax with yq)")
    try:
        return json.loads(result.stdout)
    except ValueError as exc:
        raise Error("Expected one YAML document; use mikefarah yq v4") from exc


def digest(data):
    return hashlib.sha256(data.encode()).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def safe_path(base, relative, purpose):
    require(isinstance(relative, str) and relative, f"{purpose}: expected a relative path")
    path = (base / relative).resolve()
    require(not Path(relative).is_absolute() and (path == base or base in path.parents),
            f"{purpose}: path must stay inside the project (including symlinks)")
    return path


def dotenv(path):
    """Literal values only. Never source config as shell code."""
    values = {}
    if not path.exists():
        return values
    for number, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:]
        key, sep, value = line.partition("=")
        key, value = key.strip(), value.strip()
        require(sep and ENV_NAME.fullmatch(key), f"Invalid env assignment at {path.name}:{number}")
        if value.startswith(("'", '"')):
            require(len(value) >= 2 and value[-1] == value[0], f"Unclosed env quote at {path.name}:{number}")
            value = value[1:-1]
        values[key] = value
    return values


def expand(value, environ):
    require(isinstance(value, str), "Environment and target values must be strings")
    def replacement(match):
        key = match.group(1)
        require(key in environ and environ[key] != "", f"Required environment variable is unset: {key}")
        return environ[key]
    return re.sub(r"\$\{([A-Z_][A-Z0-9_]*)\}", replacement, value)


class Project:
    def __init__(self, config=None, discover=True):
        self.path = None
        if config:
            self.path = Path(config).resolve()
            require(self.path.is_file(), "Configuration file does not exist")
        elif discover:
            for directory in (Path.cwd(), *Path.cwd().parents):
                if (directory / "ctrl.yaml").is_file():
                    self.path = directory / "ctrl.yaml"
                    break
        self.base = self.path.parent if self.path else Path.cwd()
        self.data = yaml_read(self.path.read_text()) if self.path else {}
        require(isinstance(self.data, dict), "ctrl.yaml must be a mapping")
        legacy = set(self.data) & {"services", "machines", "deployments", "scripts", "extensions", "meta"}
        require(not legacy, "ctrl 0.4 configuration detected; see ctrl help migration. Convert to operations and targets explicitly.")
        allowed = {"version", "project", "env_files", "targets", "operations"}
        require(not (set(self.data) - allowed), "Unknown configuration fields: " + ", ".join(sorted(set(self.data) - allowed)))
        require(type(self.data.get("version", 1)) is int and self.data.get("version", 1) == 1, "Unsupported configuration contract version (expected version: 1)")
        require(isinstance(self.data.get("project", self.base.name), str), "project must be a string")
        self.name = self.data.get("project", self.base.name)
        self.environ = dict(os.environ)
        env_files = self.data.get("env_files", [])
        require(isinstance(env_files, list), "env_files must be a list")
        for entry in env_files:
            path = safe_path(self.base, entry, "env_files")
            require(path.is_file(), f"Env file not found: {entry}")
            # Explicit process values win over literal project defaults.
            for key, value in dotenv(path).items():
                self.environ.setdefault(key, value)
        self.targets = self.data.get("targets", {})
        require(isinstance(self.targets, dict), "targets must be a mapping")
        self.entries = self.data.get("operations", {})
        require(isinstance(self.entries, dict), "operations must be a mapping")
        self.aliases = {}
        for name, entry in self.entries.items():
            require(isinstance(name, str) and NAME.fullmatch(name) and name not in RESERVED,
                    f"Invalid or reserved operation name: {name}")
            if isinstance(entry, str):
                entry = {"script": entry} if entry.startswith("./") else {"uses": entry}
            require(isinstance(entry, dict), f"Operation {name} must select uses or script")
            aliases = entry.get("aliases", [])
            require(isinstance(aliases, list), f"{name}: aliases must be a list")
            for alias in aliases:
                require(isinstance(alias, str) and NAME.fullmatch(alias) and alias not in RESERVED,
                        f"Invalid or reserved alias for {name}")
                require(alias not in self.entries and alias not in self.aliases, f"Duplicate alias: {alias}")
                self.aliases[alias] = name
        self.validate_targets()

    def validate_targets(self):
        for name, target in self.targets.items():
            require(isinstance(name, str) and NAME.fullmatch(name) and name != "local", "Target names must be plain tokens; local is reserved")
            require(isinstance(target, dict), f"Target {name} must be a mapping")
            require(not (set(target) - {"host", "user", "port", "key", "cwd", "environment", "host_key_policy"}), f"Unknown fields for target {name}")
            host = target.get("host", "")
            require(isinstance(host, str) and host and not host.startswith("-"), f"Target {name} requires host")
            require(isinstance(target.get("user", "root"), str) and re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_.-]*", target.get("user", "root")), f"Invalid SSH user for {name}")
            port = target.get("port", 22)
            require(type(port) is int and 1 <= port <= 65535, f"Invalid SSH port for {name}")
            require(target.get("host_key_policy", "yes") in {"yes", "accept-new"}, "host_key_policy must be yes or accept-new")
            require(isinstance(target.get("cwd", "/tmp"), str) and target.get("cwd", "/tmp").startswith("/"), f"Target {name} cwd must be absolute")
            require(isinstance(target.get("environment", {}), dict), f"Target {name} environment must be a mapping")
            for key, value in target.get("environment", {}).items():
                require(isinstance(key, str) and ENV_NAME.fullmatch(key) and isinstance(value, str), f"Invalid environment for target {name}")
                require(not key.startswith(("CTRL_", "DYLD_")) and key not in BASE_ENV and key not in UNSAFE_ENV, f"Unsafe environment key for target {name}")
            require("key" not in target or isinstance(target["key"], str), f"Target {name} key must be a path string")

    def entry(self, name, allow_library=False):
        original = name
        name = self.aliases.get(name, name)
        if name in self.entries:
            entry = self.entries[name]
            if isinstance(entry, str):
                entry = {"script": entry} if entry.startswith("./") else {"uses": entry}
            return name, entry
        if name in {"init", "project/init"}:
            return "init", {"uses": "project/init"}
        if allow_library and "/" in name:
            return name, {"uses": name}
        raise Error(f"Unknown operation '{original}'. Run ctrl help to see this project's operations.")


class Operation:
    def __init__(self, project, requested, allow_library=False):
        self.name, entry = project.entry(requested, allow_library=allow_library)
        require(not (set(entry) - {"uses", "script", "aliases", "environment", "contract"}), f"Unknown fields for operation {self.name}")
        require(("uses" in entry) != ("script" in entry), f"{self.name}: select exactly one of uses or script")
        self.script_path = None
        if "uses" in entry:
            implementation = entry["uses"]
            require(isinstance(implementation, str) and re.fullmatch(r"[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+", implementation), "Invalid supplied implementation name")
            prefix = "operations/" + implementation
            require(prefix + ".json" in assets("operations/", ".json"), f"Unknown implementation: {implementation}")
            self.script = asset(prefix + ".sh")
            self.contract = json.loads(asset(prefix + ".json"))
            require("contract" not in entry, "Supplied contracts cannot be overridden; use a project script instead")
            self.implementation = implementation
        else:
            path = safe_path(project.base, entry["script"], "script")
            require(path.is_file() and path.suffix == ".sh", f"Project script not found or not .sh: {entry['script']}")
            self.script_path = path
            self.script = path.read_text()
            if "contract" in entry:
                self.contract = entry["contract"]
            else:
                sidecar = safe_path(project.base, str(path.with_suffix(".yaml").relative_to(project.base)), "contract")
                require(sidecar.is_file(), f"Missing operation contract: {sidecar.name} (or set contract in ctrl.yaml)")
                self.contract = yaml_read(sidecar.read_text())
            self.implementation = str(path.relative_to(project.base))
        self.environment = entry.get("environment", {})
        self.validate()
        self.sha256 = digest(self.script)
        self.contract_sha256 = digest(canonical({"contract": self.contract, "environment": self.environment}))

    def validate(self):
        c = self.contract
        require(isinstance(c, dict), f"{self.name}: contract must be a mapping")
        require(not (set(c) - {"version", "description", "effects", "execution", "tools", "env", "parameters", "timeout", "interactive", "target_optional"}), f"{self.name}: unknown contract fields")
        require(type(c.get("version")) is int and c.get("version") == 1, f"{self.name}: contract requires version: 1")
        require(isinstance(c.get("description"), str) and c["description"], f"{self.name}: description is required")
        require(c.get("effects") in {"read", "write", "destructive"}, f"{self.name}: effects must be read, write, or destructive")
        require(c.get("execution") in {"local", "target", "controller"}, f"{self.name}: execution must be local, target, or controller")
        require(type(c.get("timeout", 300)) is int and c.get("timeout", 300) > 0, f"{self.name}: timeout must be a positive integer")
        require(type(c.get("interactive", False)) is bool, "interactive must be a boolean")
        require(type(c.get("target_optional", False)) is bool, "target_optional must be a boolean")
        require(not c.get("target_optional") or c["execution"] == "controller", "target_optional applies only to controller operations")
        require(not c.get("interactive") or c["execution"] == "controller", "Interactive operations must execute on the controller")
        require(isinstance(self.environment, dict), "environment must be a mapping")
        for key, value in self.environment.items():
            require(isinstance(key, str) and ENV_NAME.fullmatch(key) and isinstance(value, str), "Invalid operation environment")
            require(not key.startswith("CTRL_") and key not in BASE_ENV and key not in UNSAFE_ENV and not key.startswith("DYLD_"), "Cannot override runner or system environment")
        tools, env = c.get("tools", []), c.get("env", [])
        require(isinstance(tools, list) and all(isinstance(t, str) and NAME.fullmatch(t) for t in tools), "tools must be plain executable names")
        require(isinstance(env, list) and all(isinstance(v, str) and ENV_NAME.fullmatch(v) for v in env), "env must list environment variable names")
        require(not any(v.startswith(("CTRL_", "DYLD_")) or v in BASE_ENV or v in UNSAFE_ENV for v in env), "env cannot override runner or system environment")
        params = c.get("parameters", [])
        require(isinstance(params, list), "parameters must be a list")
        names, flags, optional = set(), set(), False
        for param in params:
            require(isinstance(param, dict), "Each parameter needs a mapping")
            require(not (set(param) - {"name", "flag", "type", "required", "default", "choices", "pattern", "secret", "description"}), "Unknown parameter fields")
            name = param.get("name", "")
            require(isinstance(name, str) and re.fullmatch(r"[a-z][a-z0-9_]*", name) and name not in names, "Parameter names must be unique lowercase identifiers")
            names.add(name)
            require(param.get("type") in {"string", "token", "integer", "boolean", "enum"}, f"Unsupported parameter type: {name}")
            require(all(type(param.get(k, False)) is bool for k in ("required", "secret")), "required and secret must be booleans")
            if "flag" in param:
                flag = param["flag"]
                require(isinstance(flag, str) and re.fullmatch(r"--[a-z][a-z0-9-]*", flag) and flag not in RUNNER_FLAGS and flag not in flags, f"Invalid, duplicate, or reserved parameter flag: {flag}")
                flags.add(flag)
            else:
                require(param["type"] != "boolean", "Boolean parameters need a flag")
                require(not optional or not param.get("required"), "Required positionals must precede optional ones")
                optional = optional or not param.get("required", False)
            if param["type"] == "enum":
                require(isinstance(param.get("choices"), list) and param["choices"] and all(isinstance(v, str) for v in param["choices"]), "enum requires string choices")
            require(not param.get("secret") or "default" not in param, "Secret parameters cannot have stored defaults; use declared env")
            if "pattern" in param:
                require(param["type"] in {"string", "token", "enum"}, "pattern applies only to string values")
                require(isinstance(param["pattern"], str), "pattern must be a regular expression")
                try:
                    re.compile(param["pattern"])
                except re.error as exc:
                    raise Error("Invalid parameter pattern") from exc
            if "default" in param:
                self.value(param, param["default"])

    @staticmethod
    def value(param, value):
        kind, name = param["type"], param["name"]
        if kind == "integer":
            require(type(value) is int or (isinstance(value, str) and re.fullmatch(r"[0-9]+", value)), f"{name}: expected a non-negative integer")
            value = int(value)
            require(value >= 0, f"{name}: expected a non-negative integer")
        elif kind == "boolean":
            require(type(value) is bool or value in ("true", "false"), f"{name}: expected true or false")
            value = value is True or value == "true"
        else:
            require(isinstance(value, str), f"{name}: expected a string")
            require("\x00" not in value and len(value) <= 4096, f"{name}: invalid or oversized value")
            if kind == "token":
                require(NAME.fullmatch(value), f"{name}: expected a plain token")
            if kind == "enum":
                require(value in param["choices"], f"{name}: choose one of {', '.join(param['choices'])}")
            if "pattern" in param:
                require(re.fullmatch(param["pattern"], value), f"{name}: value does not match its contract")
        return value

    def parse(self, args):
        params = self.contract.get("parameters", [])
        positional = [p for p in params if "flag" not in p]
        flags = {p["flag"]: p for p in params if "flag" in p}
        result, index, literal = {}, 0, False
        args = list(args)
        while args:
            arg = args.pop(0)
            if arg == "--" and not literal:
                literal = True
                continue
            if arg.startswith("-") and not literal:
                flag, sep, value = arg.partition("=")
                require(flag in flags, f"Unknown operation option: {flag}; see ctrl help {self.name}")
                param = flags[flag]
                if param["type"] == "boolean" and not sep:
                    value = True
                elif not sep:
                    require(bool(args), f"{flag}: missing value")
                    value = args.pop(0)
            else:
                require(index < len(positional), f"Unexpected positional argument; see ctrl help {self.name}")
                param, index = positional[index], index + 1
                value = arg
            require(param["name"] not in result, f"Duplicate parameter: {param['name']}")
            result[param["name"]] = self.value(param, value)
        for param in params:
            name = param["name"]
            if name not in result:
                require(not param.get("required"), f"Required parameter missing: {name}")
                if "default" in param:
                    result[name] = self.value(param, param["default"])
                elif param["type"] == "boolean":
                    result[name] = False
        return result

    def redacted(self, parameters):
        secret = {p["name"] for p in self.contract.get("parameters", []) if p.get("secret")}
        return {k: "<redacted>" if k in secret else v for k, v in parameters.items()}


class Audit:
    def __init__(self, project, operation, target, mode):
        self.id = str(uuid.uuid4())
        self.started = time.monotonic()
        self.path = project.base / ".local" / "ctrl" / "audit.jsonl"
        directory = self.path.parent.resolve()
        require(project.base == directory or project.base in directory.parents, "Audit directory must stay inside the project")
        self.fields = {"run_id": self.id, "version": VERSION, "project": project.name,
                       "operation": operation, "target": target, "mode": mode,
                       "operator": os.environ.get("USER", "unknown")}
        parent = os.environ.get("CTRL_PARENT_RUN_ID")
        if parent:
            try:
                self.fields['parent_run_id'] = str(uuid.UUID(parent))
            except ValueError:
                pass

    def write(self, event, **fields):
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        record = dict(self.fields, event=event, timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(), **fields)
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(fd, "a") as stream:
            os.fchmod(stream.fileno(), 0o600)
            fcntl.flock(stream, fcntl.LOCK_EX)
            stream.write(canonical(record) + "\n")
            stream.flush()
            os.fsync(stream.fileno())

    @contextlib.contextmanager
    def session(self):
        self.write("started")  # Fail closed if audit cannot be written.
        code, outcome = 1, "rejected"
        try:
            yield self
            code, outcome = 0, "completed"
        except SystemExit as exc:
            code = exc.code if isinstance(exc.code, int) else 1
            outcome = "completed" if code == 0 else "failed"
            raise
        except KeyboardInterrupt:
            code, outcome = 130, "cancelled"
            raise
        finally:
            self.write("finished", exit_code=code, outcome=outcome,
                       duration_s=round(time.monotonic() - self.started, 3))


def ssh_args(target, environ):
    host = expand(target["host"], environ)
    require(re.fullmatch(r"[a-zA-Z0-9_.:\[\]-]+", host) and not host.startswith("-"), "Invalid resolved SSH host")
    args = ["ssh", "-p", str(target.get("port", 22)), "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=" + target.get("host_key_policy", "yes")]
    if target.get("key"):
        args += ["-i", str(Path(expand(target["key"], environ)).expanduser())]
    return args + [target.get("user", "root") + "@" + host]


def process(command, env, cwd, timeout, input_text=None, interactive=False):
    with tempfile.TemporaryFile(mode="w+") as stdin:
        if input_text is not None:
            stdin.write(input_text)
            stdin.seek(0)
        child = subprocess.Popen(command, env=env, cwd=cwd,
                                 stdin=None if interactive else stdin,
                                 start_new_session=not interactive)
        old_handlers = {}
        def terminate(signum, _frame):
            if child.poll() is None:
                try:
                    if interactive:
                        child.send_signal(signum)
                    else:
                        os.killpg(child.pid, signum)
                except ProcessLookupError:
                    pass
            raise KeyboardInterrupt
        try:
            for signum in (signal.SIGTERM, signal.SIGINT):
                old_handlers[signum] = signal.signal(signum, terminate)
            try:
                code = child.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                if interactive:
                    child.kill()
                else:
                    os.killpg(child.pid, signal.SIGKILL)
                child.wait()
                return 124
            except KeyboardInterrupt:
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    pass
                finally:
                    # A shell may exit on TERM while its descendants ignore it.
                    # Always reap the operation's process group, even after the
                    # direct child has already exited and closed its own handles.
                    try:
                        if interactive:
                            if child.poll() is None:
                                child.kill()
                        else:
                            os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    child.wait()
                raise
            return code if code >= 0 else 128 - code
        finally:
            for signum, handler in old_handlers.items():
                signal.signal(signum, handler)


def execute(project, requested, args, options, target_name):
    audit = Audit(project, requested, target_name, "check" if options.check else "plan" if options.dry_run else "run")
    with audit.session():
        operation = Operation(project, requested)
        parameters = operation.parse(args)
        c = operation.contract
        require(target_name == "local" or target_name in project.targets, f"Unknown target: {target_name}")
        target = project.targets.get(target_name, {})
        require(c["execution"] != "local" or target_name == "local", f"{operation.name} only runs locally")
        require(c["execution"] != "controller" or target_name != "local" or c.get("target_optional"), f"{operation.name} requires --on <target>")
        remote = target_name != "local" and c["execution"] == "target"
        effective_sha256 = digest(canonical({"contract": operation.contract_sha256, "target": target}))
        audit.fields.update(operation=operation.name, implementation=operation.implementation,
                            script_sha256=operation.sha256, contract_sha256=operation.contract_sha256,
                            parameters=operation.redacted(parameters), effects=c["effects"], configuration_sha256=effective_sha256)
        env = {key: value for key, value in os.environ.items() if key in BASE_ENV}
        env["PATH"] = env.get("PATH", os.defpath)
        operation_env = dict(operation.environment, **target.get("environment", {}))
        for key, value in operation_env.items():
            require(ENV_NAME.fullmatch(key) and not key.startswith("CTRL_") and key not in BASE_ENV and key not in UNSAFE_ENV and not key.startswith("DYLD_"), "Invalid target environment key")
            env[key] = expand(value, project.environ)
        for name in c.get("env", []):
            require(project.environ.get(name), f"Required environment variable is unset: {name}")
            env[name] = project.environ[name]
        for key, value in parameters.items():
            env["CTRL_PARAM_" + key.upper()] = str(value).lower() if isinstance(value, bool) else str(value)
        cwd = target.get("cwd", "/tmp") if remote else str(project.base)
        env.update(CTRL_VERSION=VERSION, CTRL_PROJECT=project.name, CTRL_PROJECT_DIR=cwd,
                   CTRL_OPERATION=operation.name, CTRL_TARGET=target_name, CTRL_RUN_ID=audit.id,
                   CTRL_REMOTE="1" if remote else "0", CTRL_YES="1" if options.yes else "0",
                   CTRL_BIN=str(ARCHIVE if PACKAGED else ROOT / "ctrl.sh"),
                   CTRL_CONFIG_FILE=str(project.path or ""))
        if c["execution"] == "controller" and target_name != "local" and not options.dry_run:
            command = ssh_args(target, project.environ)
            env.update(CTRL_SSH_ARGS=canonical(command), CTRL_TARGET_CWD=target.get("cwd", "/tmp"))
        plan = {"operation": operation.name, "implementation": operation.implementation,
                "effects": c["effects"], "execution": c["execution"], "target": target_name,
                "cwd": cwd, "parameters": operation.redacted(parameters),
                "script_sha256": operation.sha256, "contract_sha256": operation.contract_sha256,
                "configuration_sha256": effective_sha256,
                "tools": c.get("tools", []), "environment_names": sorted(set(operation_env) | set(c.get("env", [])))}
        audit.write("validated")
        if options.dry_run:
            print(json.dumps(plan, indent=2) if options.json else
                  f"PLAN {operation.name} -> {target_name} ({operation.implementation}, {c['effects']})\n" + json.dumps(plan, indent=2))
            return
        tools = ["bash"] + c.get("tools", [])
        if remote:
            require(shutil.which("ssh"), "ssh is required")
            # Only prerequisites execute here; the operation body is not transmitted for check.
            preflight = "set -eu\ncd " + shlex.quote(cwd) + "\n"
            preflight += "\n".join("command -v " + shlex.quote(tool) + " >/dev/null || { echo 'Missing tool: " + tool + "' >&2; exit 1; }" for tool in tools) + "\n"
            code = process(ssh_args(target, project.environ) + ["bash --noprofile --norc -s"],
                           {k: v for k, v in env.items() if k in BASE_ENV}, str(project.base), 30, preflight)
            require(code == 0, "Remote preflight failed")
        else:
            for tool in tools:
                require(shutil.which(tool, path=env["PATH"]), f"Required tool not found: {tool}")
        if options.check:
            result = {"operation": operation.name, "target": target_name, "ok": True}
            print(json.dumps(result) if options.json else f"OK {operation.name} -> {target_name}")
            return
        require(not options.json, "--json is supported for help, check, and --dry-run; operation output belongs to the script")
        if c["effects"] != "read" and not options.yes:
            require(sys.stdin.isatty(), f"{operation.name} declares {c['effects']} effects; review ctrl help {operation.name}, then pass --yes")
            require(input(f"Run {operation.name} on {target_name} ({c['effects']})? [y/N] ").lower() == "y", "Operation declined")
        require(not c.get("interactive") or sys.stdin.isatty(), "Interactive operations require a terminal")
        audit.write("executing")
        if remote:
            remote_env = {k: v for k, v in env.items() if k not in BASE_ENV and k not in {"CTRL_BIN", "CTRL_CONFIG_FILE"}}
            # Quote data as shell literals; neither params nor env values become shell expressions.
            script = "set -euo pipefail\n"
            script += "\n".join("export " + k + "=" + shlex.quote(v) for k, v in remote_env.items())
            script += "\ncd " + shlex.quote(cwd) + "\n" + operation.script
            remote_command = 'env -i HOME="$HOME" PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin bash --noprofile --norc -s'
            code = process(ssh_args(target, project.environ) + [remote_command],
                           {k: v for k, v in env.items() if k in BASE_ENV}, str(project.base), c.get("timeout", 300), script)
        else:
            # Snapshot the reviewed body so on-disk changes cannot race script identity in the audit.
            with tempfile.TemporaryDirectory(prefix="ctrl-operation-") as directory:
                path = Path(directory) / "operation.sh"
                path.write_text(operation.script)
                code = process(["bash", "--noprofile", "--norc", str(path)], env, cwd,
                               c.get("timeout", 300), interactive=c.get("interactive", False))
        raise SystemExit(code)


def help_text(project, name=None, as_json=False, source=False):
    selected = bool(project and name and (name in project.entries or name in project.aliases))
    require(not source or (name and name not in RESERVED and (selected or name not in {"scripts", "config", "migration", "security", "install", "agent", "examples", "copy"})), "--source requires an operation name")
    require(not (source and as_json), "Choose --source or --json")
    if not selected and name == "examples":
        catalog = json.loads(asset("examples/catalog.json"))
        if as_json:
            print(json.dumps(catalog, indent=2))
        else:
            print("Public project examples (fictional applications)\n")
            for entry in catalog:
                print(entry["title"] + " — " + entry["description"])
                print("  Directory: examples/" + entry["path"])
                print("  Extra tools: " + ", ".join(entry["tools"]))
                print("  Try: ctrl --config examples/" + entry["path"] + "/ctrl.yaml " + entry["first"] + "\n")
            print("Example sources and walkthroughs are in the full release archive.\nEvery example also supports ctrl check, operation help, and plans.")
        return
    if not selected and name == "agent":
        require(not as_json, "Agent skill is Markdown; omit --json")
        print(asset("SKILL.md"))
        return
    if not selected and name in {"scripts", "config", "migration", "security", "install", "copy"}:
        require(not as_json, "Use ctrl help <operation> --json for a machine-readable contract")
        print(asset("docs/" + name + ".md"))
        return
    if name:
        if name in RESERVED:
            print({"help": "ctrl help [operation|scripts|config|security|install|migration|agent|examples|copy] [--json]\nctrl help --all lists supplied implementations.",
                   "run": "ctrl run <operation> [parameters] [--on target[,target]] [--dry-run] [--yes]\nctrl <operation> is the same runner. Use -- before literal operation arguments.",
                   "check": "ctrl check [operation [parameters]] [--on target[,target]] [--json]\nWithout an operation: validate the project and all configured contracts. No operation body runs.",
                   "upgrade": "ctrl upgrade [--yes]\nVerify and atomically replace a packaged installation using the latest GitHub release."}[name])
            return
        operation = Operation(project, name, allow_library=True)
        if source:
            print(operation.script, end="" if operation.script.endswith("\n") else "\n")
            return
        info = dict(operation.contract, name=operation.name, implementation=operation.implementation,
                    script_sha256=operation.sha256, contract_sha256=operation.contract_sha256,
                    aliases=[alias for alias, target in project.aliases.items() if target == operation.name],
                    configuration_env=sorted({v for value in operation.environment.values() for v in re.findall(r"\$\{([A-Z_][A-Z0-9_]*)\}", value)}))
        if as_json:
            print(json.dumps(info, indent=2))
        else:
            print(f"{operation.name}: {info['description']}\nImplementation: {operation.implementation}\nEffects: {info['effects']} | Execution: {info['execution']} | Timeout: {info.get('timeout', 300)}s")
            usage = []
            for param in info.get("parameters", []):
                label = param.get("flag", "<" + param["name"] + ">")
                if "flag" in param and param["type"] != "boolean":
                    label += " <" + param["name"] + ">"
                usage.append(label if param.get("required") else "[" + label + "]")
            print("Usage: ctrl " + operation.name + " " + " ".join(usage))
            for param in info.get("parameters", []):
                print(f"  {param.get('flag', param['name'])}: {param['type']} — {param.get('description', '')}" +
                      (f" (choices: {', '.join(param['choices'])})" if "choices" in param else "") +
                      (f" (default: {param['default']})" if "default" in param else "") +
                      (" [secret]" if param.get("secret") else ""))
            print("Tools: " + ", ".join(info.get("tools", [])) + "\nRequired env: " + ", ".join(info.get("env", [])) + "\nConfig env: " + ", ".join(info["configuration_env"]))
            print(f"Runner: --on <target[,target]>  --dry-run  --yes  --help\nRead the selected body with: ctrl help {operation.name} --source. Review before granting access.")
        return
    rows = []
    if project:
        for name in sorted(set(project.entries) | {"init"}):
            op = Operation(project, name)
            rows.append({"name": name, "description": op.contract["description"], "implementation": op.implementation,
                         "effects": op.contract["effects"], "aliases": [a for a, n in project.aliases.items() if n == name]})
    else:
        rows = [{"name": "init", "description": "Create ctrl.yaml or a contracted project script", "implementation": "project/init", "effects": "write", "aliases": []}]
    if as_json:
        print(json.dumps({"version": VERSION, "core": sorted(RESERVED), "operations": rows,
                          "targets": sorted(project.targets) if project else []}, indent=2))
    else:
        print(f"ctrl {VERSION} — discover, check, and run contracted operations\n\nCore: help  run  check  upgrade\n\nProject operations:")
        for row in rows:
            aliases = " (" + ", ".join(row["aliases"]) + ")" if row["aliases"] else ""
            print(f"  {row['name'] + aliases:22} {row['description']} [{row['effects']}]")
        print("\nctrl <operation> --help    selected implementation and typed parameters\nctrl help scripts         how to write an operation\nctrl help --all            supplied implementations\nctrl check                validate this project's contracts\nctrl --version")


def upgrade(yes):
    require(PACKAGED, "Source checkouts are updated with git; upgrade only replaces installed release executables")
    require(yes, "Pass --yes to download, verify, and install the latest release")
    base = "https://github.com/bitboyro/ctrl/releases/latest/download/"
    with urllib.request.urlopen(base + "ctrl.sha256", timeout=30) as response:
        expected = response.read(4096).decode().split()[0]
    require(re.fullmatch(r"[a-fA-F0-9]{64}", expected), "Invalid checksum")
    with urllib.request.urlopen(base + "ctrl", timeout=60) as response:
        payload = response.read(10_000_001)
    require(len(payload) <= 10_000_000 and hashlib.sha256(payload).hexdigest() == expected, "Release checksum mismatch")
    fd, path = tempfile.mkstemp(prefix=".ctrl-upgrade-", dir=ARCHIVE.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload)
        os.chmod(path, 0o755)
        require(zipfile.is_zipfile(path), "Release is not a ctrl executable archive")
        result = subprocess.run([sys.executable, path, "--version"], capture_output=True, text=True, timeout=10)
        require(result.returncode == 0 and result.stdout.startswith("ctrl "), "Release sanity check failed")
        os.replace(path, ARCHIVE)
        print("Installed " + result.stdout.strip())
    finally:
        if os.path.exists(path):
            os.unlink(path)


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    if args == ["--version"]:
        print("ctrl " + VERSION)
        return 0
    # Runner flags are parsed once, identically for explicit run and shortcuts.
    options = argparse.Namespace(config=None, on="local", yes=False, dry_run=False, json=False, check=False, all=False, source=False)
    rest, literal = [], False
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--":
            rest.extend(args[index:])
            break
        if arg in {"--config", "--on"}:
            require(index + 1 < len(args), f"{arg} requires a value")
            setattr(options, arg[2:], args[index + 1])
            index += 2
            continue
        if arg in {"--yes", "--dry-run", "--json", "--all", "--source"}:
            setattr(options, arg[2:].replace("-", "_"), True)
        else:
            rest.append(arg)
        index += 1
    if not rest:
        rest = ["help"]
    command, tail = rest[0], rest[1:]
    if command == "--version" and not tail:
        print("ctrl " + VERSION)
        return 0
    if command == "--help":
        command = "help"
    require(not options.source or (command == "help" and len(tail) == 1), "Usage: ctrl help <operation> --source")
    if command == "upgrade":
        require(not tail and not options.dry_run and options.on == "local", "Usage: ctrl upgrade --yes")
        upgrade(options.yes)
        return 0
    if command == "help" and len(tail) == 1 and tail[0] in RESERVED:
        help_text(None, tail[0], options.json, options.source)
        return 0
    if command == "help" and tail and tail[0] in {"scripts", "config", "migration", "security", "install", "agent", "examples", "copy"}:
        require(len(tail) == 1, "Usage: ctrl help <topic>")
        # Enabled operations take precedence over documentation topic names.
        # Static docs must still work when yq/configuration is absent or broken.
        try:
            candidate = Project(options.config)
        except (Error, OSError, ValueError, TypeError, KeyError):
            candidate = None
        help_text(candidate, tail[0], options.json, options.source)
        return 0
    if command == "help" and options.all:
        require(not tail, "Usage: ctrl help --all")
        rows = []
        for path in assets("operations/", ".json"):
            c = json.loads(asset(path))
            rows.append({"implementation": path[len("operations/"):-5], "description": c["description"], "effects": c["effects"]})
        print(json.dumps(rows, indent=2) if options.json else "\n".join(f"{r['implementation']:24} {r['description']} [{r['effects']}]" for r in rows))
        return 0
    require(not options.all, "--all is only supported by ctrl help --all")
    if command == "help" and len(tail) == 1 and "/" in tail[0]:
        help_text(Project(discover=False), tail[0], options.json, options.source)
        return 0
    # Bare help must work even with a broken/legacy project configuration.
    try:
        bootstrap = (command == "init" or (command == "run" and tail and tail[0] in {"init", "project/init"})) and "--script" not in tail
        project = Project(options.config, discover=not (bootstrap and not (Path.cwd() / "ctrl.yaml").is_file()))
    except Error as exc:
        if command == "help" and not options.json and not tail:
            print(f"Project configuration: {exc}\n", file=sys.stderr)
            help_text(None)
            return 0
        raise
    if command == "help":
        require(len(tail) <= 1, "Usage: ctrl help [operation|topic]")
        help_text(project, tail[0] if tail else None, options.json, options.source)
        return 0
    if command == "check" and not tail:
        require(options.on == "local" and not options.dry_run, "Use ctrl check <operation> --on <target> for execution preflight")
        for name in project.entries:
            Operation(project, name)
        require(project.path is not None, "No ctrl.yaml found; run ctrl init")
        print(json.dumps({"ok": True, "operations": len(project.entries), "targets": len(project.targets)}) if options.json else f"OK configuration: {len(project.entries)} operations, {len(project.targets)} targets")
        return 0
    if command in {"run", "check"}:
        require(bool(tail), f"Usage: ctrl {command} <operation> [parameters]")
        requested, tail = tail[0], tail[1:]
        options.check = command == "check"
    else:
        requested = command
    if "--help" in tail and ("--" not in tail or tail.index("--help") < tail.index("--")):
        help_text(project, requested, options.json)
        return 0
    require(requested not in RESERVED, "Core commands cannot be invoked as operations")
    targets = options.on.split(",")
    require(all(t and (t == "local" or NAME.fullmatch(t)) for t in targets) and len(set(targets)) == len(targets), "Targets must be a comma-separated list of unique names")
    require(len(targets) <= 32, "At most 32 explicit targets per invocation")
    # Validate the complete target set before any target can change.
    if not all(t == "local" or t in project.targets for t in targets):
        with Audit(project, requested, options.on, "check" if options.check else "run").session():
            raise Error("Unknown target in --on selection")
    failed = 0
    for target in targets:
        try:
            execute(project, requested, tail, options, target)
        except SystemExit as exc:
            failed = failed or exc.code
        except Error as exc:
            print("error: " + str(exc), file=sys.stderr)
            failed = failed or 1
    return failed


if __name__ == "__main__":
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        sys.exit(main())
    except (Error, OSError, ValueError) as exc:
        print("error: " + str(exc), file=sys.stderr)
        sys.exit(1)
    except (TypeError, KeyError):
        print("error: Invalid configuration or contract structure", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("cancelled", file=sys.stderr)
        sys.exit(130)
