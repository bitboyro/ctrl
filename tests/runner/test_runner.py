"""Behavioral tests: no production SSH, Docker workloads, or sibling mutations."""
import concurrent.futures
import hashlib
import importlib.util
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

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'ctrl.sh'
PACKAGE = ROOT / 'dist/ctrl'


class RunnerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(['bash', str(ROOT / 'build.sh')], check=True, capture_output=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ctrl-test-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.capture = self.base / 'capture.jsonl'
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        self.env.pop('CTRL_CONFIG', None)
        self.data = {'version': 1, 'project': 'test', 'operations': {}, 'targets': {}}
        self.config = self.base / 'ctrl.yaml'
        self.write_config()

    def write_config(self):
        # JSON is valid YAML and avoids a test-only package dependency.
        self.config.write_text(json.dumps(self.data))

    def operation(self, name='hello', body='printf "hello\\n"', **contract):
        directory = self.base / 'scripts'
        directory.mkdir(exist_ok=True)
        (directory / (name + '.sh')).write_text('#!/usr/bin/env bash\nset -euo pipefail\n' + body + '\n')
        manifest = dict(version=1, description='Test operation', effects='read', execution='local', tools=[], parameters=[])
        manifest.update(contract)
        (directory / (name + '.yaml')).write_text(json.dumps(manifest))
        self.data['operations'][name] = './scripts/' + name + '.sh'
        self.write_config()
        return manifest

    def run_ctrl(self, *args, packaged=False, env=None):
        command = str(PACKAGE if packaged else SOURCE)
        return subprocess.run([command, '--config', str(self.config), *args], cwd=self.base,
                              env=env or self.env, text=True, capture_output=True, timeout=20)

    def records(self):
        path = self.base / '.local/ctrl/audit.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def fake(self, name, code):
        path = self.bin / name
        path.write_text('#!' + sys.executable + '\n' + code)
        path.chmod(0o755)
        return path

    def fake_docker(self, exit_code=0):
        return self.fake('docker', f'''import json,sys
with open({str(self.capture)!r},'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
raise SystemExit({exit_code})
''')

    def fake_ssh(self, execute=True):
        self.fake('ssh', f'''import json,sys,os,subprocess
body=sys.stdin.read()
with open({str(self.capture)!r},'a') as f: f.write(json.dumps({{'argv':sys.argv[1:],'stdin':body}})+'\\n')
{'raise SystemExit(subprocess.run(["bash","--noprofile","--norc","-s"],input=body,text=True).returncode)' if execute else 'raise SystemExit(0)'}
''')

    def target(self):
        self.data['targets']['prod'] = dict(host='example.test', user='deploy', cwd=str(self.base))
        self.write_config()

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_four_core_commands_and_explicit_operation_discovery(self):
        self.operation()
        result = self.run_ctrl('help', '--json')
        self.assert_ok(result)
        info = json.loads(result.stdout)
        self.assertEqual(info['core'], ['check', 'help', 'run', 'upgrade'])
        self.assertEqual({o['name'] for o in info['operations']}, {'hello', 'init'})
        self.assertNotIn('compose/status', result.stdout)

    def test_offline_docs_without_yq_or_configuration(self):
        # /usr/bin/env needs a Python on Linux/macOS; invoke interpreter explicitly.
        result = subprocess.run([sys.executable, str(PACKAGE), 'help', 'scripts'], cwd=self.base,
                                env=dict(self.env, PATH='/nonexistent'), text=True, capture_output=True)
        self.assert_ok(result)
        self.assertIn('CTRL_PARAM_', result.stdout)

    def test_help_and_version_work_inside_legacy_project(self):
        self.config.write_text('meta: {project: old}\nservices: []\n')
        self.assert_ok(self.run_ctrl('help'))
        self.assert_ok(self.run_ctrl('--version'))
        result = self.run_ctrl('check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('migration', result.stderr)

    def test_shortcut_explicit_run_and_alias_share_identity(self):
        self.operation()
        self.data['operations']['hello'] = dict(script='./scripts/hello.sh', aliases=['hi'])
        self.write_config()
        for args in [('hello',), ('run', 'hello'), ('hi',)]:
            self.assert_ok(self.run_ctrl(*args))
        finished = [r for r in self.records() if r['event'] == 'finished']
        self.assertEqual({r['operation'] for r in finished}, {'hello'})
        self.assertEqual(len({r['script_sha256'] for r in finished}), 1)
        self.assertEqual(len(finished), 3)

    def test_config_and_contract_checks_do_not_execute(self):
        self.operation(body='touch should-not-exist')
        self.assert_ok(self.run_ctrl('check'))
        self.assert_ok(self.run_ctrl('check', 'hello'))
        self.assertFalse((self.base / 'should-not-exist').exists())
        self.assertEqual(self.records()[-1]['mode'], 'check')

    def test_typed_parameters_and_defaults(self):
        self.operation(body='python3 -c \'import os,json;print(json.dumps({k:v for k,v in os.environ.items() if k.startswith("CTRL_PARAM_")}))\'',
                       tools=['python3'], parameters=[
                           dict(name='service', type='enum', choices=['api', 'web'], required=True),
                           dict(name='lines', flag='--lines', type='integer', default=5),
                           dict(name='follow', flag='--follow', type='boolean')])
        result = self.run_ctrl('hello', 'api', '--follow')
        self.assert_ok(result)
        self.assertEqual(json.loads(result.stdout), dict(CTRL_PARAM_SERVICE='api', CTRL_PARAM_LINES='5', CTRL_PARAM_FOLLOW='true'))
        self.assertNotEqual(self.run_ctrl('hello', 'other').returncode, 0)
        self.assertNotEqual(self.run_ctrl('hello', 'api', '--lines', '-1').returncode, 0)

    def test_unknown_duplicate_extra_and_missing_inputs_rejected(self):
        self.operation(body='touch executed', parameters=[dict(name='name', type='token', required=True),
                       dict(name='count', flag='--count', type='integer')])
        for args in [(), ('one', 'two'), ('one', '--wat'), ('one', '--count'),
                     ('one', '--count', '1', '--count', '2'), ('bad;touch pwned',)]:
            self.assertNotEqual(self.run_ctrl('hello', *args).returncode, 0)
        self.assertFalse((self.base / 'executed').exists())
        self.assertEqual(len([r for r in self.records() if r.get('outcome') == 'rejected']), 6)

    def test_literal_shell_payload_does_not_execute(self):
        self.operation(body='printf "%s" "$CTRL_PARAM_value"'.replace('PARAM_value', 'PARAM_VALUE'),
                       parameters=[dict(name='value', type='string', required=True)])
        payload = "$(touch pwned); 'quoted' `touch pwned2`"
        result = self.run_ctrl('hello', '--', payload)
        self.assert_ok(result)
        self.assertEqual(result.stdout, payload)
        self.assertFalse((self.base / 'pwned').exists())
        self.assertFalse((self.base / 'pwned2').exists())

    def test_write_requires_confirmation_but_check_and_plan_do_not(self):
        self.operation(body='touch executed', effects='write')
        self.assertNotEqual(self.run_ctrl('hello').returncode, 0)
        self.assert_ok(self.run_ctrl('check', 'hello'))
        self.assert_ok(self.run_ctrl('hello', '--dry-run'))
        self.assertFalse((self.base / 'executed').exists())
        self.assert_ok(self.run_ctrl('hello', '--yes'))
        self.assertTrue((self.base / 'executed').exists())

    def test_secret_parameters_redacted_in_plan_and_journal(self):
        self.operation(body='printf "%s" "$CTRL_PARAM_SECRET"', parameters=[dict(name='secret', flag='--secret', type='string', secret=True, required=True)])
        result = self.run_ctrl('hello', '--secret', 'private-value', '--dry-run', '--json')
        self.assert_ok(result)
        self.assertNotIn('private-value', result.stdout)
        result = self.run_ctrl('hello', '--secret', 'private-value')
        self.assert_ok(result)
        self.assertEqual(result.stdout, 'private-value')
        self.assertNotIn('private-value', json.dumps(self.records()))
        self.assertEqual(self.records()[-1]['parameters']['secret'], '<redacted>')

    def test_clean_environment_only_declared_credentials_forwarded(self):
        self.operation(body='python3 -c \'import os,json;print(json.dumps(dict(os.environ)))\'', tools=['python3'], env=['APP_TOKEN'])
        env = dict(self.env, APP_TOKEN='required-secret', OTHER_SECRET='never-forward')
        result = self.run_ctrl('hello', env=env)
        self.assert_ok(result)
        values = json.loads(result.stdout)
        self.assertEqual(values['APP_TOKEN'], 'required-secret')
        self.assertNotIn('OTHER_SECRET', values)
        self.assertNotIn('required-secret', json.dumps(self.records()))

    def test_dotenv_literal_not_shell_and_process_takes_precedence(self):
        self.operation(body='printf "%s" "$APP_TOKEN"', env=['APP_TOKEN'])
        (self.base / 'secrets.env').write_text('APP_TOKEN="$(touch pwned)"\n')
        self.data['env_files'] = ['secrets.env']
        self.write_config()
        result = self.run_ctrl('hello')
        self.assert_ok(result)
        self.assertEqual(result.stdout, '$(touch pwned)')
        self.assertFalse((self.base / 'pwned').exists())
        self.assertEqual(self.run_ctrl('hello', env=dict(self.env, APP_TOKEN='override')).stdout, 'override')

    def test_missing_env_and_tools_prevent_execution(self):
        self.operation(body='touch executed', env=['UNSET_TEST_VARIABLE'])
        self.assertNotEqual(self.run_ctrl('hello').returncode, 0)
        self.operation(body='touch executed', tools=['ctrl_missing_zzzzzz'])
        self.assertNotEqual(self.run_ctrl('hello').returncode, 0)
        self.assertFalse((self.base / 'executed').exists())

    def test_sidecar_path_cannot_escape_through_symlink(self):
        self.operation()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'external.sh'
            path.write_text('echo bad')
            (self.base / 'scripts/link.sh').symlink_to(path)
            self.data['operations']['escape'] = './scripts/link.sh'
            self.write_config()
            self.assertNotEqual(self.run_ctrl('check').returncode, 0)

    def test_contract_symlink_cannot_escape_project(self):
        self.operation()
        sidecar = self.base / 'scripts/hello.yaml'
        text = sidecar.read_text()
        sidecar.unlink()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'external.yaml'
            path.write_text(text)
            sidecar.symlink_to(path)
            self.assertNotEqual(self.run_ctrl('check').returncode, 0)

    def test_invalid_alias_reserved_names_and_collisions(self):
        self.operation()
        for aliases in [['help'], ['hello'], ['bad name'], ['dup', 'dup']]:
            self.data['operations']['hello'] = dict(script='./scripts/hello.sh', aliases=aliases)
            self.write_config()
            self.assertNotEqual(self.run_ctrl('check').returncode, 0)

    def test_cannot_weaken_supplied_contract_or_use_unknown_fields(self):
        self.data['operations']['deploy'] = dict(uses='compose/deploy', contract=dict(effects='read'))
        self.write_config()
        self.assertNotEqual(self.run_ctrl('check').returncode, 0)
        self.operation(unknown='surprise')
        self.assertNotEqual(self.run_ctrl('check').returncode, 0)

    def test_reject_environment_loader_injection(self):
        self.operation(env=['BASH_ENV'])
        self.assertNotEqual(self.run_ctrl('check').returncode, 0)
        self.operation()
        self.data['operations']['hello'] = dict(script='./scripts/hello.sh', environment=dict(PYTHONPATH='evil'))
        self.write_config()
        self.assertNotEqual(self.run_ctrl('check').returncode, 0)

    def test_operation_failure_propagates_and_is_audited(self):
        self.operation(body='echo failure >&2; exit 17')
        result = self.run_ctrl('hello')
        self.assertEqual(result.returncode, 17)
        self.assertEqual(self.records()[-1]['exit_code'], 17)
        self.assertEqual(self.records()[-1]['outcome'], 'failed')

    def test_unwritable_or_symlinked_audit_blocks_execution(self):
        self.operation(body='touch executed')
        journal = self.base / '.local/ctrl/audit.jsonl'
        journal.mkdir(parents=True)
        self.assertNotEqual(self.run_ctrl('hello').returncode, 0)
        self.assertFalse((self.base / 'executed').exists())
        journal.rmdir()
        other = self.base / 'other'
        other.write_text('unchanged')
        journal.symlink_to(other)
        self.assertNotEqual(self.run_ctrl('hello').returncode, 0)
        self.assertEqual(other.read_text(), 'unchanged')

    def test_audit_has_identity_hashes_and_private_permissions(self):
        self.operation()
        self.assert_ok(self.run_ctrl('hello'))
        events = self.records()
        self.assertEqual([r['event'] for r in events], ['started', 'validated', 'executing', 'finished'])
        self.assertEqual(len({r['run_id'] for r in events}), 1)
        expected = hashlib.sha256((self.base / 'scripts/hello.sh').read_bytes()).hexdigest()
        self.assertEqual(events[-1]['script_sha256'], expected)
        self.assertEqual((self.base / '.local/ctrl/audit.jsonl').stat().st_mode & 0o777, 0o600)

    def test_concurrent_audit_lines_are_complete_json(self):
        self.operation()
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(lambda _: self.run_ctrl('hello'), range(12)))
        for result in results:
            self.assert_ok(result)
        self.assertEqual(len([r for r in self.records() if r['event'] == 'finished']), 12)
        self.assertEqual(len({r['run_id'] for r in self.records()}), 12)

    def test_timeout_terminates_and_records_result(self):
        self.operation(body='sleep 30; touch too-late', timeout=1)
        result = self.run_ctrl('hello')
        self.assertEqual(result.returncode, 124)
        self.assertEqual(self.records()[-1]['exit_code'], 124)
        self.assertFalse((self.base / 'too-late').exists())

    def test_cancellation_records_and_kills_child(self):
        self.operation(body='touch ready; sleep 30; touch too-late')
        child = subprocess.Popen([str(SOURCE), '--config', str(self.config), 'hello'], cwd=self.base,
                                 env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            while not (self.base / 'ready').exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue((self.base / 'ready').exists())
            child.send_signal(signal.SIGTERM)
            stdout, stderr = child.communicate(timeout=5)
            self.assertEqual(child.returncode, 130, stdout + stderr)
            self.assertEqual(self.records()[-1]['outcome'], 'cancelled')
            self.assertFalse((self.base / 'too-late').exists())
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate()

    def test_remote_plan_never_connects_or_transmits_secret(self):
        self.operation(execution='target', env=['APP_TOKEN'])
        self.target()
        self.fake_ssh()
        result = self.run_ctrl('hello', '--on', 'prod', '--dry-run', env=dict(self.env, APP_TOKEN='secret'))
        self.assert_ok(result)
        self.assertFalse(self.capture.exists())
        self.assertNotIn('secret', result.stdout)

    def test_remote_check_transmits_only_prerequisites(self):
        self.operation(body='echo DO_NOT_SEND_THIS_OPERATION', execution='target', env=['APP_TOKEN'])
        self.target()
        self.fake_ssh()
        self.assert_ok(self.run_ctrl('check', 'hello', '--on', 'prod', env=dict(self.env, APP_TOKEN='private-token')))
        records = [json.loads(line) for line in self.capture.read_text().splitlines()]
        self.assertEqual(len(records), 1)
        self.assertNotIn('DO_NOT_SEND_THIS_OPERATION', records[0]['stdin'])
        self.assertNotIn('private-token', records[0]['stdin'])
        self.assertIn('StrictHostKeyChecking=yes', records[0]['argv'])

    def test_remote_execution_quotes_params_and_keeps_secrets_off_ssh_argv(self):
        self.operation(body='printf "%s\\n%s" "$CTRL_PARAM_VALUE" "$APP_TOKEN"', execution='target', env=['APP_TOKEN'],
                       parameters=[dict(name='value', type='string', required=True)])
        self.target()
        self.fake_ssh()
        payload = "$(touch pwned) ' \\ ; `touch pwned2`\nnext"
        result = self.run_ctrl('hello', '--on', 'prod', '--', payload, env=dict(self.env, APP_TOKEN='private-token'))
        self.assert_ok(result)
        self.assertEqual(result.stdout, payload + '\nprivate-token')
        captured = [json.loads(line) for line in self.capture.read_text().splitlines()]
        self.assertEqual(len(captured), 2)
        self.assertNotIn('private-token', json.dumps([r['argv'] for r in captured]))
        self.assertNotIn('private-token', json.dumps(self.records()))
        self.assertFalse((self.base / 'pwned').exists())

    def test_remote_failure_code_and_local_only_rejection(self):
        self.operation(body='exit 23', execution='target')
        self.target()
        self.fake_ssh()
        self.assertEqual(self.run_ctrl('hello', '--on', 'prod').returncode, 23)
        self.operation()
        self.assertNotEqual(self.run_ctrl('hello', '--on', 'prod').returncode, 0)

    def test_multi_target_unknown_rejected_before_any_work(self):
        self.operation(body='touch executed', execution='target')
        self.assertNotEqual(self.run_ctrl('hello', '--on', 'local,missing').returncode, 0)
        self.assertFalse((self.base / 'executed').exists())
        self.assertEqual(self.records()[-1]['outcome'], 'rejected')

    def test_multi_target_failure_returns_nonzero_and_continues(self):
        self.operation(body='[[ "$CTRL_REMOTE" == 0 ]] && exit 9; echo remote', execution='target')
        self.target()
        self.fake_ssh()
        result = self.run_ctrl('hello', '--on', 'local,prod')
        self.assertEqual(result.returncode, 9)
        self.assertIn('remote', result.stdout)
        finished = [r for r in self.records() if r['event'] == 'finished']
        self.assertEqual([r['exit_code'] for r in finished], [9, 0])

    def test_source_and_package_help_contract_and_execution_parity(self):
        self.operation()
        for args in [('help', '--json'), ('help', 'hello', '--json'), ('hello',), ('check',)]:
            source = self.run_ctrl(*args)
            package = self.run_ctrl(*args, packaged=True)
            self.assert_ok(source)
            self.assertEqual(source.returncode, package.returncode)
            self.assertEqual(source.stdout, package.stdout)

    def test_supplied_contracts_and_offline_docs_in_package(self):
        for executable in (SOURCE, PACKAGE):
            result = subprocess.run([str(executable), 'help', '--all', '--json'], cwd=self.base, env=self.env, text=True, capture_output=True)
            self.assert_ok(result)
            implementations = [r['implementation'] for r in json.loads(result.stdout)]
            self.assertEqual(len(implementations), 11)
            for name in implementations:
                self.assert_ok(self.run_ctrl('help', name, '--json', packaged=executable == PACKAGE))
            for topic in ('scripts', 'config', 'security', 'install', 'migration', 'agent', 'examples', 'copy'):
                self.assert_ok(self.run_ctrl('help', topic, packaged=executable == PACKAGE))

    def test_compose_command_arrays_and_failure_stops_deploy(self):
        self.fake_docker()
        self.data['operations'] = {'deploy': 'compose/deploy', 'logs': 'compose/logs'}
        self.write_config()
        self.assert_ok(self.run_ctrl('deploy', 'api', '--yes'))
        rows = [json.loads(line) for line in self.capture.read_text().splitlines()]
        self.assertEqual(rows, [['compose', '-f', 'docker-compose.yml', 'pull', 'api'], ['compose', '-f', 'docker-compose.yml', 'up', '-d', 'api']])
        self.capture.unlink()
        self.fake_docker(12)
        self.assertEqual(self.run_ctrl('deploy', 'api', '--yes').returncode, 12)
        self.assertEqual(len(self.capture.read_text().splitlines()), 1)

    def test_compose_logs_options_are_typed_and_forwarded(self):
        self.fake_docker()
        self.data['operations'] = {'logs': 'compose/logs'}
        self.write_config()
        self.assert_ok(self.run_ctrl('logs', 'api', '--lines', '25', '--follow'))
        rows = [json.loads(line) for line in self.capture.read_text().splitlines()]
        self.assertEqual(rows[0][-5:], ['logs', '--tail', '25', '--follow', 'api'])

    def test_target_environment_overrides_operation_defaults(self):
        self.operation(body='printf "%s" "$COMPOSE_FILE"', execution='target')
        self.data['operations']['hello'] = dict(script='./scripts/hello.sh', environment=dict(COMPOSE_FILE='local.yml'))
        self.target()
        self.data['targets']['prod']['environment'] = dict(COMPOSE_FILE='remote.yml')
        self.write_config()
        self.fake_ssh()
        self.assertEqual(self.run_ctrl('hello', '--on', 'prod').stdout, 'remote.yml')

    def test_sync_primitive_protects_paths_and_ssh_argv(self):
        self.target()
        self.data['operations'] = {'sync': 'host/sync'}
        self.write_config()
        self.fake('rsync', f'import sys,json\nopen({str(self.capture)!r},"w").write(json.dumps(sys.argv[1:]))\n')
        self.fake_ssh(execute=False)
        self.assert_ok(self.run_ctrl('sync', 'folder with spaces/', '/srv/app dir/', '--on', 'prod', '--yes'))
        row = json.loads(self.capture.read_text())
        self.assertIn('--protect-args', row)
        self.assertEqual(row[-2:], ['folder with spaces/', 'deploy@example.test:/srv/app dir/'])
        self.assertNotIn('--delete', row)

    def test_init_script_starter_is_small_valid_and_runnable(self):
        self.assert_ok(self.run_ctrl('init', '--script', 'starter', '--yes'))
        script = self.base / 'scripts/starter.sh'
        self.assertLess(len(script.read_text().splitlines()), 10)
        self.data['operations'] = {'starter': './scripts/starter.sh'}
        self.write_config()
        self.assert_ok(self.run_ctrl('check'))
        result = self.run_ctrl('starter')
        self.assert_ok(result)
        self.assertIn('Hello from starter', result.stdout)
        self.assertNotEqual(self.run_ctrl('init', '--script', 'starter', '--yes').returncode, 0)

    def test_init_creates_new_config_instead_of_editing_parent(self):
        nested = self.base / 'nested'
        nested.mkdir()
        result = subprocess.run([str(SOURCE), 'init', '--yes'], cwd=nested, env=self.env, text=True, capture_output=True)
        self.assert_ok(result)
        self.assertTrue((nested / 'ctrl.yaml').exists())
        self.assertIn('.local/', (nested / '.gitignore').read_text())

    def test_package_checksum_and_local_installer(self):
        directory = self.base / 'install-bin'
        result = subprocess.run(['bash', str(ROOT / 'install.sh'), '--from', str(ROOT / 'dist')],
                                cwd=self.base, env=dict(self.env, CTRL_BIN_DIR=str(directory)), text=True, capture_output=True)
        self.assert_ok(result)
        self.assertEqual((directory / 'ctrl').read_bytes(), PACKAGE.read_bytes())
        bad = self.base / 'bad-package'
        bad.mkdir()
        (bad / 'ctrl').write_bytes(PACKAGE.read_bytes() + b'changed')
        shutil.copy(ROOT / 'dist/ctrl.sha256', bad)
        before = (directory / 'ctrl').read_bytes()
        result = subprocess.run(['bash', str(ROOT / 'install.sh'), '--from', str(bad)],
                                cwd=self.base, env=dict(self.env, CTRL_BIN_DIR=str(directory)), text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((directory / 'ctrl').read_bytes(), before)

    def test_source_upgrade_never_replaces_checkout(self):
        result = self.run_ctrl('upgrade', '--yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Source checkouts', result.stderr)

    def test_generic_example_checks_and_alias_is_discoverable(self):
        example = ROOT / 'examples/compose-app'
        destination = self.base / 'example'
        shutil.copytree(example, destination, ignore=shutil.ignore_patterns('.local'))
        self.config = destination / 'ctrl.yaml'
        self.assert_ok(self.run_ctrl('check'))
        result = self.run_ctrl('help', 'rd', '--json')
        self.assert_ok(result)
        info = json.loads(result.stdout)
        self.assertEqual(info['implementation'], 'compose/redeploy')
        self.assertEqual(info['aliases'], ['rd'])
        env = dict(self.env, APP_DIR='/review/demo-app', APP_URL='https://app.example.invalid')
        self.assert_ok(self.run_ctrl('build', 'api', '--tag', 'review', '--dry-run', env=env))
        self.assertNotEqual(self.run_ctrl('build', 'not-implemented', '--tag', 'review', '--dry-run', env=env).returncode, 0)
        self.assert_ok(self.run_ctrl('smoke', '--dry-run', env=env))
        # Remote plan contains neither a connection nor a requirement to resolve host secrets.
        self.assert_ok(self.run_ctrl('rd', 'api', '--on', 'prod', '--dry-run', env=env))


    def test_all_supplied_operations_have_valid_bash_syntax(self):
        for path in sorted((ROOT / 'operations').glob('*/*.sh')):
            result = subprocess.run(['bash', '-n', str(path)], capture_output=True, text=True)
            self.assert_ok(result)

    def test_invalid_contract_defaults_and_reserved_flags(self):
        for parameter in [dict(name='n', type='integer', default='bad'),
                          dict(name='yes', type='boolean', flag='--yes'),
                          dict(name='secret', type='string', secret=True, default='never-store'),
                          dict(name='flag', type='boolean'),
                          dict(name='n', type='integer', pattern='.*')]:
            self.operation(parameters=[parameter])
            result = self.run_ctrl('check')
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('Traceback', result.stderr)

    def test_invalid_structures_fail_without_traceback(self):
        self.operation(effects={'invalid': 'mapping'})
        result = self.run_ctrl('check')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Traceback', result.stderr)

    def test_target_loader_environment_rejected_during_config_check(self):
        self.target()
        self.data['targets']['prod']['environment'] = dict(BASH_ENV='/tmp/payload')
        self.write_config()
        self.assertNotEqual(self.run_ctrl('check').returncode, 0)

    def test_invalid_resolved_ssh_host_rejected_before_connect(self):
        self.operation(execution='target')
        self.target()
        self.data['targets']['prod']['host'] = '${TEST_HOST}'
        self.write_config()
        self.fake_ssh()
        result = self.run_ctrl('hello', '--on', 'prod', env=dict(self.env, TEST_HOST='-oProxyCommand=touch pwned'))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.capture.exists())

    def test_audit_directory_cannot_escape_via_symlink(self):
        self.operation(body='touch executed')
        with tempfile.TemporaryDirectory() as directory:
            (self.base / '.local').symlink_to(Path(directory), target_is_directory=True)
            self.assertNotEqual(self.run_ctrl('hello').returncode, 0)
            self.assertFalse((self.base / 'executed').exists())
            self.assertFalse((Path(directory) / 'ctrl/audit.jsonl').exists())

    def test_docker_build_has_no_framework_detection_and_explicit_push(self):
        self.fake_docker()
        self.data['operations']['build'] = 'docker/build'
        self.write_config()
        self.assert_ok(self.run_ctrl('build', 'example/app:review', '--context', 'some path', '--yes'))
        rows = [json.loads(line) for line in self.capture.read_text().splitlines()]
        self.assertEqual(rows, [['build', '-f', 'Dockerfile', '-t', 'example/app:review', 'some path']])
        self.capture.unlink()
        self.assert_ok(self.run_ctrl('build', 'example/app:review', '--push', '--yes'))
        rows = [json.loads(line) for line in self.capture.read_text().splitlines()]
        self.assertEqual(rows[-1], ['push', 'example/app:review'])

    def test_restart_and_redeploy_have_different_commands(self):
        self.fake_docker()
        self.data['operations'] = {'restart': 'compose/restart', 'redeploy': 'compose/redeploy'}
        self.write_config()
        self.assert_ok(self.run_ctrl('restart', 'api', '--yes'))
        rows = [json.loads(line) for line in self.capture.read_text().splitlines()]
        self.assertEqual(rows, [['compose', '-f', 'docker-compose.yml', 'restart', 'api']])
        self.capture.unlink()
        self.assert_ok(self.run_ctrl('redeploy', 'api', '--yes'))
        rows = [json.loads(line) for line in self.capture.read_text().splitlines()]
        self.assertEqual(rows[-1], ['compose', '-f', 'docker-compose.yml', 'up', '-d', '--force-recreate', 'api'])

    def test_interactive_ssh_rejects_nonterminal_execution(self):
        self.target()
        self.data['operations']['ssh'] = 'host/ssh'
        self.write_config()
        self.fake_ssh(execute=False)
        self.assert_ok(self.run_ctrl('check', 'ssh', '--on', 'prod'))
        self.assertNotEqual(self.run_ctrl('ssh', '--on', 'prod', '--yes').returncode, 0)
        self.assertFalse(self.capture.exists())

    def test_interactive_ssh_preserves_terminal_stdin(self):
        import pty
        import termios
        import fcntl
        self.target()
        self.data['operations']['ssh'] = 'host/ssh'
        self.write_config()
        self.fake('ssh', f"import os,json,sys\nopen({str(self.capture)!r},'w').write(json.dumps(dict(tty=os.isatty(0),argv=sys.argv[1:])))\n")
        try:
            master, slave = pty.openpty()
        except OSError:
            self.skipTest('No pseudo-terminal available')
        def terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        child = subprocess.Popen([str(SOURCE), '--config', str(self.config), 'ssh', '--on', 'prod', '--yes'],
                                 cwd=self.base, env=self.env, stdin=slave, stdout=slave, stderr=slave,
                                 preexec_fn=terminal)
        os.close(slave)
        try:
            code = child.wait(timeout=8)
            self.assertEqual(code, 0)
            captured = json.loads(self.capture.read_text())
            self.assertTrue(captured['tty'])
            self.assertIn('-t', captured['argv'])
            self.assertEqual(self.records()[-1]['exit_code'], 0)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
            os.close(master)

    def test_upgrade_checksum_mismatch_never_replaces_executable(self):
        import io
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location('ctrl_test_upgrade', ROOT / 'src/ctrl.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        installed = self.base / 'installed-ctrl'
        installed.write_bytes(PACKAGE.read_bytes())
        module.PACKAGED, module.ARCHIVE = True, installed
        before = installed.read_bytes()
        with patch.object(module.urllib.request, 'urlopen', side_effect=[io.BytesIO(('0' * 64 + ' ctrl').encode()), io.BytesIO(b'wrong payload')]):
            with self.assertRaises(module.Error):
                module.upgrade(True)
        self.assertEqual(installed.read_bytes(), before)

    def test_upgrade_verifies_and_atomically_installs_package(self):
        import io
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location('ctrl_test_upgrade_ok', ROOT / 'src/ctrl.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        installed = self.base / 'installed-ctrl'
        installed.write_bytes(b'old executable')
        module.PACKAGED, module.ARCHIVE = True, installed
        payload = PACKAGE.read_bytes()
        with patch.object(module.urllib.request, 'urlopen', side_effect=[io.BytesIO((hashlib.sha256(payload).hexdigest() + ' ctrl').encode()), io.BytesIO(payload)]):
            module.upgrade(True)
        self.assertEqual(installed.read_bytes(), payload)
        self.assertEqual(installed.stat().st_mode & 0o777, 0o755)

    def test_unenabled_library_cannot_bypass_project_allowlist(self):
        self.assert_ok(self.run_ctrl('help', 'compose/status', '--json'))
        self.fake_docker()
        result = self.run_ctrl('run', 'compose/status')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.capture.exists())
        self.assertEqual(self.records()[-1]['outcome'], 'rejected')


    def test_completion_reads_operation_flags_and_enum_choices(self):
        self.operation(parameters=[dict(name='mode', flag='--mode', type='enum', choices=['fast', 'careful'])])
        self.fake('ctrl', f'import os,sys\nos.execv({str(SOURCE)!r},[{str(SOURCE)!r}]+sys.argv[1:])\n')
        script = 'source "$1"; COMP_WORDS=(ctrl hello --); COMP_CWORD=2; _ctrl; printf "%s\\n" "${COMPREPLY[@]}"'
        result = subprocess.run(['bash', '-c', script, 'completion-test', str(ROOT / 'completions/ctrl.bash')],
                                cwd=self.base, env=self.env, text=True, capture_output=True)
        self.assert_ok(result)
        self.assertIn('--mode', result.stdout)
        script = 'source "$1"; COMP_WORDS=(ctrl hello --mode c); COMP_CWORD=3; _ctrl; printf "%s\\n" "${COMPREPLY[@]}"'
        result = subprocess.run(['bash', '-c', script, 'completion-test', str(ROOT / 'completions/ctrl.bash')],
                                cwd=self.base, env=self.env, text=True, capture_output=True)
        self.assert_ok(result)
        self.assertIn('careful', result.stdout)

    def test_full_archive_can_install_and_serve_offline_help(self):
        import tarfile
        version = (ROOT / 'VERSION').read_text().strip()
        archive = ROOT / ('dist/ctrl-' + version + '.tar.gz')
        directory = self.base / 'unpacked'
        directory.mkdir()
        with tarfile.open(archive) as source:
            self.assertFalse(any('/.local/' in n or '__pycache__' in n for n in source.getnames()))
            # Only our locally built, reviewed archive is extracted in this fixture.
            source.extractall(directory)
        package = directory / ('ctrl-' + version)
        self.assertTrue((package / 'operations/compose/deploy.sh').is_file())
        self.assertTrue((package / 'examples/compose-app/ctrl.yaml').is_file())
        destination = self.base / 'installed'
        result = subprocess.run(['bash', str(package / 'install.sh'), '--from', '.'], cwd=package,
                                env=dict(self.env, CTRL_BIN_DIR=str(destination)), text=True, capture_output=True)
        self.assert_ok(result)
        result = subprocess.run([str(destination / 'ctrl'), 'help', 'scripts'], cwd=self.base,
                                env=self.env, text=True, capture_output=True)
        self.assert_ok(result)
        self.assertIn('Writing an operation', result.stdout)


    def test_help_source_serves_exact_selected_body_from_package(self):
        self.operation()
        expected = (self.base / 'scripts/hello.sh').read_text()
        self.assertEqual(self.run_ctrl('help', 'hello', '--source', packaged=True).stdout, expected)
        result = self.run_ctrl('help', 'compose/deploy', '--source', packaged=True)
        self.assert_ok(result)
        self.assertEqual(result.stdout, (ROOT / 'operations/compose/deploy.sh').read_text())
        self.assertNotEqual(self.run_ctrl('hello', '--source').returncode, 0)

    def test_help_reports_config_environment_names_without_values(self):
        self.operation()
        self.data['operations']['hello'] = dict(script='./scripts/hello.sh', environment={'API_TOKEN': '${PROJECT_TOKEN}'})
        self.write_config()
        result = self.run_ctrl('help', 'hello', '--json', env=dict(self.env, PROJECT_TOKEN='never-show'))
        self.assert_ok(result)
        self.assertEqual(json.loads(result.stdout)['configuration_env'], ['PROJECT_TOKEN'])
        self.assertNotIn('never-show', result.stdout)


    def test_build_excludes_generated_and_private_example_files(self):
        import tarfile
        fixture = self.base / 'build-fixture'
        for directory in ('scripts', 'src', 'operations', 'docs', 'completions', 'examples/compose-app/.local', 'examples/compose-app/__pycache__'):
            (fixture / directory).mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / 'scripts/build.py', fixture / 'scripts/build.py')
        shutil.copy(ROOT / 'src/ctrl.py', fixture / 'src/ctrl.py')
        (fixture / 'VERSION').write_text('1.2.3\n')
        for name in ('README.md', 'SKILL.md', 'install.sh'):
            (fixture / name).write_text('public')
        for name in ('.local/audit.jsonl', '__pycache__/private.pyc', '.env', 'secrets.env', 'private.local.yaml'):
            (fixture / 'examples/compose-app' / name).write_text('PRIVATE-CONTENT-NEVER-SHIP')
        (fixture / 'examples/compose-app/README.md').write_text('public example')
        (fixture / 'examples/catalog.json').write_text(json.dumps([{'path': 'compose-app'}]))
        (fixture / 'examples/README.md').write_text('public index')
        private = fixture / 'examples/private-infrastructure'
        private.mkdir()
        (private / 'README.md').write_text('PRIVATE-CONTENT-NEVER-SHIP')
        subprocess.run([sys.executable, str(fixture / 'scripts/build.py')], check=True, capture_output=True)
        with tarfile.open(fixture / 'dist/ctrl-1.2.3.tar.gz') as archive:
            names = archive.getnames()
            self.assertIn('ctrl-1.2.3/examples/compose-app/README.md', names)
            for name in names:
                self.assertNotIn('.local/', name)
                self.assertNotIn('__pycache__', name)
                if archive.getmember(name).isfile():
                    self.assertNotIn(b'PRIVATE-CONTENT-NEVER-SHIP', archive.extractfile(name).read())


    def test_distribution_examples_are_explicitly_allowlisted(self):
        import tarfile
        version = (ROOT / 'VERSION').read_text().strip()
        allowed = {entry['path'] for entry in json.loads((ROOT / 'examples/catalog.json').read_text())}
        with tarfile.open(ROOT / ('dist/ctrl-' + version + '.tar.gz')) as archive:
            for name in archive.getnames():
                relative = name.split('/', 1)[1] if '/' in name else ''
                if relative.startswith('examples/'):
                    first = relative.split('/')[1]
                    self.assertIn(first, allowed | {'catalog.json', 'README.md'}, name)


    def password_transport(self, password='fixture password $() with spaces'):
        self.target()
        self.data['targets']['prod']['password_env'] = 'SERVER_PASSWORD'
        self.data['targets']['prod']['key'] = '${UNSET_FUTURE_KEY}'
        self.write_config()
        self.env['SERVER_PASSWORD'] = password
        self.auth_capture = self.base / 'auth.jsonl'
        self.fake('sshpass', f'''import json,os,sys
from pathlib import Path
secret=Path(sys.argv[2])
with open({str(self.auth_capture)!r},'a') as f:
 f.write(json.dumps(dict(argv=sys.argv[1:],mode=secret.stat().st_mode & 0o777,path=str(secret),password=secret.read_text().rstrip('\\n')))+'\\n')
os.execv(sys.argv[3],sys.argv[3:])
''')
        return password

    def test_password_transport_keeps_secret_off_argv_remote_environment_and_audit(self):
        self.operation(body='printf "%s" "${SERVER_PASSWORD-unset}"', execution='target')
        password = self.password_transport()
        self.fake_ssh()
        result = self.run_ctrl('hello', '--on', 'prod')
        self.assert_ok(result)
        self.assertEqual(result.stdout, 'unset')
        self.assertNotIn(password, self.capture.read_text() + json.dumps(self.records()))
        calls = [json.loads(line) for line in self.auth_capture.read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        for call in calls:
            self.assertEqual(call['mode'], 0o600)
            self.assertEqual(call['password'], password)
            self.assertNotIn(password, json.dumps(call['argv']))
            self.assertFalse(Path(call['path']).exists())
        self.assertIn('BatchMode=no', json.loads(self.capture.read_text().splitlines()[0])['argv'])

    def test_password_plan_needs_no_credential_and_never_invokes_transport(self):
        self.operation(execution='target')
        password = self.password_transport()
        del self.env['SERVER_PASSWORD']
        self.fake_ssh()
        self.assert_ok(self.run_ctrl('hello', '--on', 'prod', '--dry-run'))
        self.assertFalse(self.auth_capture.exists())
        self.assertFalse(self.capture.exists())
        result = self.run_ctrl('hello', '--on', 'prod')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(password, result.stderr)
        self.assertFalse(self.capture.exists())

    def test_password_env_name_is_validated_and_literal_password_field_rejected(self):
        self.target()
        for fields in [dict(password='secret'),dict(password_env='${SECRET}'),dict(password_env='PATH'),dict(password_env='CTRL_SECRET')]:
            self.data['targets']['prod'] = dict(host='example.test', **fields)
            self.write_config()
            self.assertNotEqual(self.run_ctrl('check').returncode, 0)

    def test_password_failure_removes_private_credential_file(self):
        self.operation(execution='target')
        password = self.password_transport()
        self.fake('ssh', 'raise SystemExit(5)')
        result = self.run_ctrl('hello', '--on', 'prod')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(password, result.stdout + result.stderr + json.dumps(self.records()))
        calls = [json.loads(line) for line in self.auth_capture.read_text().splitlines()]
        self.assertTrue(calls)
        self.assertFalse(Path(calls[0]['path']).exists())

    def test_password_copy_delegation_preserves_explicit_process_credential(self):
        password = self.password_transport()
        self.data['operations']['cp'] = 'host/copy'
        self.write_config()
        self.fake('scp', '''import json,os,subprocess,sys
args=sys.argv[1:]
transport=args[args.index('-S')+1]
raise SystemExit(subprocess.run([transport,'fixture-host','true']).returncode)
''')
        self.fake('ssh', 'raise SystemExit(0)')
        source = self.base / 'file';source.write_text('data')
        result = self.run_ctrl('cp', str(source), 'prod:/tmp/file', '--yes')
        self.assert_ok(result)
        self.assertNotIn(password, json.dumps(self.records()))
        calls = [json.loads(line) for line in self.auth_capture.read_text().splitlines()]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]['password'], password)
        self.assertFalse(Path(calls[0]['path']).exists())

    def key_setup_fixture(self):
        self.target()
        self.data['operations']['ssh-key-setup'] = 'host/ssh-key-setup'
        self.write_config()
        self.key = self.base / 'client key'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.key)], check=True)
        self.remote_home = self.base / 'remote home'
        self.remote_home.mkdir()
        self.env['FIXTURE_REMOTE_HOME'] = str(self.remote_home)
        self.fake('ssh', '''import os,subprocess,sys
if sys.argv[-1]=='sh -s':
 raise SystemExit(subprocess.run(['sh','-s'],input=sys.stdin.read(),text=True,env=dict(os.environ,HOME=os.environ['FIXTURE_REMOTE_HOME'])).returncode)
if os.environ.get('FIXTURE_VERIFY_FAILURE'):raise SystemExit(255)
key=sys.argv[sys.argv.index('-i')+1]
pub=subprocess.check_output(['ssh-keygen','-y','-f',key],text=True).split()[:2]
from pathlib import Path
lines=(Path(os.environ['FIXTURE_REMOTE_HOME'])/'.ssh/authorized_keys').read_text().splitlines()
raise SystemExit(0 if any(line.split()[:2]==pub for line in lines) else 255)
''')
        # Controller receives only explicitly declared environment.
        self.data['operations']['ssh-key-setup'] = dict(uses='host/ssh-key-setup',environment={'FIXTURE_REMOTE_HOME':str(self.remote_home)})
        self.write_config()

    def test_key_setup_preserves_existing_keys_and_is_idempotent(self):
        self.key_setup_fixture()
        directory = self.remote_home / '.ssh';directory.mkdir()
        authorized = directory / 'authorized_keys'
        authorized.write_text('existing-key-line\n')
        args = ('ssh-key-setup', '--on', 'prod', '--key', str(self.key), '--yes')
        result = self.run_ctrl(*args)
        self.assert_ok(result)
        self.assertIn('Key-only login verified', result.stdout)
        installed = authorized.read_text()
        self.assertIn('existing-key-line', installed)
        self.assertEqual(installed.count(Path(str(self.key)+'.pub').read_text().strip()),1)
        backups = list(directory.glob('authorized_keys.ctrl-backup.*'))
        self.assertEqual(len(backups),1)
        self.assertEqual(backups[0].read_text(),'existing-key-line\n')
        self.assertEqual(authorized.stat().st_mode & 0o777,0o600)
        self.assert_ok(self.run_ctrl(*args,packaged=True))
        self.assertEqual(authorized.read_text(),installed)
        self.assertEqual(len(list(directory.glob('authorized_keys.ctrl-backup.*'))),1)
        self.assertNotIn(self.key.read_text(), result.stdout + result.stderr + json.dumps(self.records()))

    def test_key_setup_plan_and_missing_consent_do_not_change_remote_keys(self):
        self.key_setup_fixture()
        args = ('ssh-key-setup', '--on', 'prod', '--key', str(self.key))
        self.assert_ok(self.run_ctrl(*args,'--dry-run'))
        self.assertNotEqual(self.run_ctrl(*args).returncode,0)
        self.assertFalse((self.remote_home/'.ssh').exists())

    def test_key_setup_verification_failure_is_explicit_and_does_not_rewrite_config(self):
        self.key_setup_fixture()
        self.data['operations']['ssh-key-setup']['environment']['FIXTURE_VERIFY_FAILURE']='1'
        self.write_config()
        original = self.config.read_bytes()
        result = self.run_ctrl('ssh-key-setup','--on','prod','--key',str(self.key),'--yes')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Key was authorized, but key-only verification failed',result.stderr)
        self.assertEqual(self.config.read_bytes(),original)
        self.assertTrue((self.remote_home/'.ssh/authorized_keys').exists())

    def test_key_setup_refuses_symlinked_authorization_file(self):
        self.key_setup_fixture()
        directory = self.remote_home/'.ssh';directory.mkdir()
        other = self.remote_home/'untouched';other.write_text('keep')
        (directory/'authorized_keys').symlink_to(other)
        result = self.run_ctrl('ssh-key-setup','--on','prod','--key',str(self.key),'--yes')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(other.read_text(),'keep')

    def test_password_transport_timeout_cleans_credentials(self):
        self.operation(body='sleep 30', execution='target', timeout=1)
        self.password_transport()
        self.fake_ssh()
        result = self.run_ctrl('hello', '--on', 'prod')
        self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
        calls = [json.loads(line) for line in self.auth_capture.read_text().splitlines()]
        self.assertTrue(calls)
        self.assertTrue(all(not Path(call['path']).exists() for call in calls))
        self.assertEqual(self.records()[-1]['exit_code'], 124)

if __name__ == '__main__':
    unittest.main()
