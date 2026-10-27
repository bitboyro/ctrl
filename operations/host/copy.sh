#!/usr/bin/env bash
set -euo pipefail
exec python3 - <<'PY'
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import shutil
import subprocess
import sys
import tempfile

source = os.environ['CTRL_PARAM_SOURCE']
destination = os.environ['CTRL_PARAM_DESTINATION']
recursive = os.environ['CTRL_PARAM_RECURSIVE'] == 'true'
download = os.environ['CTRL_PARAM_DOWNLOAD'] == 'true'
preserve = os.environ['CTRL_PARAM_PRESERVE'] == 'true'
selected = os.environ['CTRL_TARGET']


def endpoint(value):
    match = re.fullmatch(r'([A-Za-z0-9][A-Za-z0-9_.-]*):(.*)', value)
    if not match:
        return None, value
    if not match[2]:
        raise ValueError('Remote endpoint needs a path')
    return match[1], match[2]


def remote_path(value):
    if not value or any(c in value for c in '*?[]\r\n') or value.startswith('~'):
        raise ValueError('Use one literal remote path without globs, newlines, or ~; prefer an absolute path')
    if not value.startswith('/'):
        value = posixpath.join(os.environ['CTRL_TARGET_CWD'], value)
    return value


def delegate(target, src, dst, pull=False):
    args = [os.environ['CTRL_BIN'], 'run', os.environ['CTRL_OPERATION'], '--on', target, '--yes']
    if os.environ.get('CTRL_CONFIG_FILE'):
        args += ['--config', os.environ['CTRL_CONFIG_FILE']]
    if recursive:
        args.append('--recursive')
    if pull:
        args.append('--download')
    if not preserve:
        args.append('--preserve=false')
    # Runner options precede --; literal file names cannot become control flags.
    args += ['--', src, dst]
    env = dict(os.environ, CTRL_PARENT_RUN_ID=os.environ["CTRL_RUN_ID"])
    result = subprocess.run(args, env=env)
    if result.returncode:
        raise SystemExit(result.returncode)


try:
    src_target, src_path = endpoint(source)
    dst_target, dst_path = endpoint(destination)
    if selected != 'local' and (src_target or dst_target):
        raise ValueError('Use either target:/path endpoints or --on TARGET, not both')
    if download and (selected == 'local' or src_target or dst_target):
        raise ValueError('--download requires --on TARGET and plain paths')

    targets = {target for target in (src_target, dst_target) if target}
    if targets:
        lookup = [os.environ['CTRL_BIN'], 'help', '--json']
        if os.environ.get('CTRL_CONFIG_FILE'):
            lookup += ['--config', os.environ['CTRL_CONFIG_FILE']]
        info = subprocess.run(lookup, capture_output=True, text=True)
        if info.returncode:
            print(info.stderr, file=sys.stderr, end='')
            raise SystemExit(info.returncode)
        if not targets.issubset(set(json.loads(info.stdout)['targets'])):
            raise ValueError('Unknown copy target; use a name declared in ctrl.yaml targets')
    if src_target and dst_target:
        # A private local relay works with different users/keys/ports on each
        # target and does not require one remote host to trust the other.
        name = PurePosixPath(src_path.rstrip('/')).name
        if name in ('', '.', '..'):
            raise ValueError('Remote relay needs a named file or directory')
        with tempfile.TemporaryDirectory(prefix='ctrl-copy-relay-') as directory:
            relay = str(Path(directory) / name)
            delegate(src_target, src_path, relay, pull=True)
            delegate(dst_target, relay, dst_path)
    elif src_target:
        delegate(src_target, src_path, destination, pull=True)
    elif dst_target:
        delegate(dst_target, source, dst_path)
    elif selected == 'local':
        src, dst = Path(source), Path(destination)
        if src.is_dir():
            if not recursive:
                raise ValueError('Directory copies require --recursive')
            if dst.is_dir():
                dst = dst / src.name
            if dst.resolve() == src.resolve() or src.resolve() in dst.resolve().parents:
                raise ValueError('Cannot copy a directory into itself or one of its descendants')
            shutil.copytree(src, dst, dirs_exist_ok=True,
                            copy_function=shutil.copy2 if preserve else shutil.copy)
        elif preserve:
            shutil.copy2(src, dst)
        else:
            shutil.copy(src, dst)
    else:
        ssh = json.loads(os.environ['CTRL_SSH_ARGS'])
        # Force SFTP (-s): remote file names are data, never remote shell code.
        # -S preserves the reviewed SSH transport adapter used by the runner.
        args = ['scp', '-s', '-S', ssh[0]]
        if recursive:
            args.append('-r')
        if preserve:
            args.append('-p')
        for value in ssh[1:-1]:
            args.append('-P' if value == '-p' else value)
        remote = remote_path(source if download else destination)
        remote = ssh[-1] + ':' + remote
        local = str(Path(destination if download else source).resolve())
        args += ['--', remote, local] if download else ['--', local, remote]
        raise SystemExit(subprocess.run(args).returncode)
except (OSError, ValueError, shutil.Error) as exc:
    print('copy: ' + str(exc), file=sys.stderr)
    raise SystemExit(1)
PY
