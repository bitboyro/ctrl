"""Failure injection and observable safety guarantees, rather than implementation mirrors."""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]


class ResilienceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(['bash', str(ROOT / 'build.sh')], check=True, capture_output=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ctrl-resilience-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        spec = importlib.util.spec_from_file_location('ctrl_resilience', ROOT / 'src/ctrl.py')
        self.ctrl = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.ctrl)
        self.script = self.base / 'task.sh'
        self.contract = dict(version=1, description='Test operation', effects='read', execution='local', parameters=[])
        self.data = dict(version=1, project='resilience', operations={'task': './task.sh'})
        self.write('printf "reviewed\\n"')
        self.options = argparse.Namespace(check=False, dry_run=False, json=False, yes=False)

    def write(self, body):
        self.script.write_text('#!/usr/bin/env bash\nset -euo pipefail\n' + body + '\n')
        self.script.with_suffix('.yaml').write_text(json.dumps(self.contract))
        self.config = self.base / 'ctrl.yaml'
        self.config.write_text(json.dumps(self.data))

    def records(self):
        return [json.loads(line) for line in (self.base / '.local/ctrl/audit.jsonl').read_text().splitlines()]

    def run_ctrl(self, *args, packaged=False):
        return subprocess.run([str(ROOT / ('dist/ctrl' if packaged else 'ctrl.sh')), '--config', str(self.config), *args],
                              cwd=self.base, env=self.env, capture_output=True, text=True, timeout=15)

    def execute(self):
        with patch.dict(os.environ, self.env, clear=True):
            return self.ctrl.execute(self.ctrl.Project(str(self.config)), 'task', [], self.options, 'local')

    def test_reviewed_script_snapshot_survives_source_mutation(self):
        self.write('printf reviewed > result')
        reviewed = self.script.read_bytes()
        original = self.ctrl.Audit.write
        def mutate(audit, event, **fields):
            original(audit, event, **fields)
            if event == 'validated':
                self.script.write_text('touch pwned\nprintf changed > result\n')
        with patch.object(self.ctrl.Audit, 'write', mutate), self.assertRaises(SystemExit) as result:
            self.execute()
        self.assertEqual(result.exception.code, 0)
        self.assertEqual((self.base / 'result').read_text(), 'reviewed')
        self.assertFalse((self.base / 'pwned').exists())
        self.assertEqual(self.records()[-1]['script_sha256'], hashlib.sha256(reviewed).hexdigest())

    def test_failed_audit_at_each_preexecution_boundary_prevents_side_effects(self):
        self.write('touch executed')
        original = self.ctrl.Audit.write
        for boundary in ('started', 'validated', 'executing'):
            with self.subTest(boundary=boundary):
                def disk_failure(audit, event, **fields):
                    if event == boundary:
                        raise OSError('simulated disk full')
                    original(audit, event, **fields)
                with patch.object(self.ctrl.Audit, 'write', disk_failure), self.assertRaises(OSError):
                    self.execute()
                self.assertFalse((self.base / 'executed').exists())

    def test_audit_flush_failure_prevents_execution(self):
        self.write('touch executed')
        with patch.object(self.ctrl.os, 'fsync', side_effect=OSError('simulated flush failure')), self.assertRaises(OSError):
            self.execute()
        self.assertFalse((self.base / 'executed').exists())

    def test_source_and_contract_changes_invalidate_review_identity(self):
        self.assertEqual(self.run_ctrl('task', '--dry-run', '--json').returncode, 0)
        initial = self.records()[-1]
        self.write('printf "different implementation\\n"')
        self.assertEqual(self.run_ctrl('task', '--dry-run', '--json').returncode, 0)
        body_changed = self.records()[-1]
        self.assertNotEqual(initial['script_sha256'], body_changed['script_sha256'])
        self.assertEqual(initial['contract_sha256'], body_changed['contract_sha256'])
        self.contract['effects'] = 'destructive'
        self.write('printf "different implementation\\n"')
        self.assertEqual(self.run_ctrl('task', '--dry-run', '--json').returncode, 0)
        self.assertNotEqual(body_changed['contract_sha256'], self.records()[-1]['contract_sha256'])

    def test_cancel_kills_stubborn_descendant_after_parent_exits(self):
        worker = self.base / 'worker.py'
        worker.write_text('''import os,signal,time
from pathlib import Path
signal.signal(signal.SIGTERM,signal.SIG_IGN)
Path('worker.pid').write_text(str(os.getpid()))
while True:
    Path('heartbeat').write_text(str(time.monotonic_ns()))
    time.sleep(.03)
''')
        self.write('python3 worker.py &\nwait')
        child = subprocess.Popen([str(ROOT / 'ctrl.sh'), '--config', str(self.config), 'task'], cwd=self.base,
                                 env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            while not (self.base / 'heartbeat').exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue((self.base / 'heartbeat').exists())
            child.send_signal(signal.SIGTERM)
            child.communicate(timeout=6)
            self.assertEqual(child.returncode, 130)
            # A surviving child would keep changing this file after ctrl has returned.
            time.sleep(.1)
            stopped = (self.base / 'heartbeat').read_text()
            time.sleep(.25)
            self.assertEqual((self.base / 'heartbeat').read_text(), stopped, 'Cancellation left a child process running')
            self.assertEqual(self.records()[-1]['outcome'], 'cancelled')
        finally:
            pid = self.base / 'worker.pid'
            if pid.exists():
                with contextlib.suppress(ProcessLookupError):
                    os.kill(int(pid.read_text()), signal.SIGKILL)
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=3)

    def test_timeout_kills_descendant_and_preserves_failed_audit(self):
        self.contract['timeout'] = 1
        self.write('sleep 2; touch escaped-timeout')
        result = self.run_ctrl('task')
        self.assertEqual(result.returncode, 124)
        time.sleep(1.25)
        self.assertFalse((self.base / 'escaped-timeout').exists())
        self.assertEqual(self.records()[-1]['exit_code'], 124)

    def test_failed_remote_preflight_does_not_transmit_body_or_credentials(self):
        self.contract.update(execution='target', env=['APP_TOKEN'])
        self.data['targets'] = {'demo': dict(host='example.invalid', cwd='/tmp')}
        self.write('echo OPERATION_BODY_MUST_NOT_BE_SENT')
        capture = self.base / 'ssh.json'
        shim = self.bin / 'ssh'
        shim.write_text('#!' + sys.executable + '\nimport sys,json,os\n' +
                        f'open({str(capture)!r},"w").write(json.dumps(dict(stdin=sys.stdin.read(),argv=sys.argv,env=dict(os.environ))))\n' +
                        'raise SystemExit(255)\n')
        shim.chmod(0o755)
        self.env['APP_TOKEN'] = 'private-value'
        result = self.run_ctrl('task', '--on', 'demo')
        self.assertNotEqual(result.returncode, 0)
        captured = json.loads(capture.read_text())
        self.assertNotIn('OPERATION_BODY_MUST_NOT_BE_SENT', captured['stdin'])
        self.assertNotIn('private-value', json.dumps(captured))
        self.assertNotIn('executing', [r['event'] for r in self.records()])

    def test_declined_confirmation_produces_no_operation_side_effects(self):
        self.contract['effects'] = 'write'
        self.write('touch executed')
        with patch.object(self.ctrl.sys.stdin, 'isatty', return_value=True), patch('builtins.input', return_value='n'), self.assertRaises(self.ctrl.Error):
            self.execute()
        self.assertFalse((self.base / 'executed').exists())
        self.assertEqual(self.records()[-1]['outcome'], 'rejected')

    def test_relocated_package_needs_no_source_tree_and_resolves_project_from_nested_cwd(self):
        deployed = self.base / 'standalone'
        shutil.copy(ROOT / 'dist/ctrl', deployed)
        nested = self.base / 'nested' / 'directory'
        nested.mkdir(parents=True)
        self.write('printf "%s" "$CTRL_PROJECT_DIR"')
        result = subprocess.run([str(deployed), 'task'], cwd=nested, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(result.stdout), self.base)

    def test_help_topics_cannot_hide_enabled_operation_contracts(self):
        for name in ('config', 'scripts', 'security', 'install', 'migration', 'agent', 'examples'):
            with self.subTest(name=name):
                self.data['operations'] = {name: './task.sh'}
                self.write('echo selected-project-operation')
                result = self.run_ctrl('help', name, '--json')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)['implementation'], 'task.sh')
                source = self.run_ctrl('help', name, '--source')
                self.assertEqual(source.stdout, self.script.read_text())
                shortcut = self.run_ctrl(name, '--help', '--json')
                self.assertEqual(json.loads(shortcut.stdout)['implementation'], 'task.sh')

    def prepare_upgrade(self, payload):
        self.installed = self.base / 'installed'
        self.installed.write_bytes(b'existing executable')
        self.ctrl.ARCHIVE, self.ctrl.PACKAGED = self.installed, True
        responses = [io.BytesIO((hashlib.sha256(payload).hexdigest() + ' ctrl').encode()), io.BytesIO(payload)]
        return patch.object(self.ctrl.urllib.request, 'urlopen', side_effect=responses)

    def test_upgrade_sanity_failure_preserves_previous_executable_and_cleans_tempfile(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as archive:
            archive.writestr('__main__.py', 'raise SystemExit(23)\n')
        with self.prepare_upgrade(buffer.getvalue()), self.assertRaises(self.ctrl.Error):
            self.ctrl.upgrade(True)
        self.assertEqual(self.installed.read_bytes(), b'existing executable')
        self.assertFalse(list(self.base.glob('.ctrl-upgrade-*')))

    def test_upgrade_atomic_replace_failure_preserves_previous_executable(self):
        with self.prepare_upgrade((ROOT / 'dist/ctrl').read_bytes()), patch.object(self.ctrl.os, 'replace', side_effect=OSError('simulated rename failure')), self.assertRaises(OSError):
            self.ctrl.upgrade(True)
        self.assertEqual(self.installed.read_bytes(), b'existing executable')
        self.assertFalse(list(self.base.glob('.ctrl-upgrade-*')))

    def test_interrupted_download_preserves_previous_executable(self):
        installed = self.base / 'installed'
        installed.write_bytes(b'old executable')
        self.ctrl.ARCHIVE, self.ctrl.PACKAGED = installed, True
        with patch.object(self.ctrl.urllib.request, 'urlopen', side_effect=OSError('network interrupted')), self.assertRaises(OSError):
            self.ctrl.upgrade(True)
        self.assertEqual(installed.read_bytes(), b'old executable')
        self.assertFalse(list(self.base.glob('.ctrl-upgrade-*')))
