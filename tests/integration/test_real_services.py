"""Opt-in integration against disposable local Docker resources and real OpenSSH.

No host Docker socket mounts, privileged containers, production targets, registries
for pushes, global pruning, or changes to the user's SSH files.
"""
import base64
import contextlib
import http.client
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
DOCKER_ENDPOINT = None


def run(*args, timeout=30, **kwargs):
    args = list(args)
    if args and args[0] == 'docker' and DOCKER_ENDPOINT:
        args = ['docker', '--host', DOCKER_ENDPOINT] + args[1:]
        env = dict(kwargs.pop('env', os.environ))
        env.pop('DOCKER_CONTEXT', None)
        env['DOCKER_HOST'] = DOCKER_ENDPOINT
        kwargs['env'] = env
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, **kwargs)


def checked(*args, timeout=30, **kwargs):
    result = run(*args, timeout=timeout, **kwargs)
    if result.returncode:
        raise RuntimeError('Command failed: ' + shlex.join(list(args)) + '\n' + result.stdout + result.stderr)
    return result.stdout.strip()


def local_docker_endpoint(environ):
    # Docker gives DOCKER_CONTEXT precedence over DOCKER_HOST. Resolve that
    # exact selection before touching a daemon, then freeze it for all calls.
    context = environ.get('DOCKER_CONTEXT')
    if context:
        endpoint = checked('docker', 'context', 'inspect', context, '--format', '{{.Endpoints.docker.Host}}', env=environ)
    elif environ.get('DOCKER_HOST'):
        endpoint = environ['DOCKER_HOST']
    else:
        context = checked('docker', 'context', 'show', env=environ)
        endpoint = checked('docker', 'context', 'inspect', context, '--format', '{{.Endpoints.docker.Host}}', env=environ)
    if not endpoint.startswith('unix://'):
        raise RuntimeError('Integration requires a local unix-socket Docker context; refusing ' + endpoint)
    return endpoint


def docker_adapter(directory, binary, endpoint):
    # ctrl deliberately filters the caller's Docker environment. Pin the local
    # endpoint in argv so a different default context cannot redirect operations.
    path = directory / 'docker'
    path.write_text('#!' + sys.executable + '\nimport os,sys\n' +
                    'env=dict(os.environ)\nenv.pop("DOCKER_CONTEXT",None)\n' +
                    'env["DOCKER_HOST"]=' + repr(endpoint) + '\n' +
                    'os.execve(' + repr(binary) + ',[' + repr(binary) + ',"--host",' + repr(endpoint) + ']+sys.argv[1:],env)\n')
    path.chmod(0o755)
    return path


class RealServicesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.environ.get('CTRL_REAL_INTEGRATION') != '1':
            raise unittest.SkipTest('Opt in with CTRL_REAL_INTEGRATION=1; requires a local Docker daemon')
        for tool in ('docker', 'ssh', 'ssh-keygen', 'sshpass', 'yq', 'python3'):
            if not shutil.which(tool):
                raise RuntimeError('Real integration prerequisite missing: ' + tool)
        global DOCKER_ENDPOINT
        DOCKER_ENDPOINT = None
        DOCKER_ENDPOINT = local_docker_endpoint(dict(os.environ))
        cls.docker = shutil.which('docker')
        cls.docker_endpoint = DOCKER_ENDPOINT
        cls.docker_env = dict(os.environ, DOCKER_HOST=DOCKER_ENDPOINT)
        cls.docker_env.pop('DOCKER_CONTEXT', None)
        checked('docker', 'info', '--format', '{{.ServerVersion}}', timeout=10)
        checked('docker', 'compose', 'version', timeout=10)
        checked('bash', str(ROOT / 'build.sh'))
        cls.sandbox = tempfile.TemporaryDirectory(prefix='ctrl-real-integration-')
        cls.addClassCleanup(cls.sandbox.cleanup)
        cls.base = Path(cls.sandbox.name).resolve()
        cls.token = uuid.uuid4().hex[:12]
        cls.image = 'ctrl-integration-ssh:' + cls.token
        cls.network = 'ctrl-integration-' + cls.token
        cls.container = None
        cls.container_name = 'ctrl-it-ssh-' + cls.token
        cls.key = cls.base / 'client key'
        checked('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(cls.key))
        build = cls.base / 'image'
        build.mkdir()
        shutil.copy(cls.key.with_suffix('.pub'), build / 'authorized_keys')
        (build / 'Dockerfile').write_text('''FROM python:3.12-alpine
ARG TARGETARCH
RUN apk add --no-cache bash openssh rsync \\
 && echo 'root:ctrl-fixture-password' | chpasswd \\
 && mkdir -p /run/sshd /root/.ssh \\
 && chmod 700 /root/.ssh \\
 && ssh-keygen -A \\
 && wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_${TARGETARCH} \\
 && chmod 755 /usr/local/bin/yq
COPY authorized_keys /root/.ssh/authorized_keys
RUN chmod 600 /root/.ssh/authorized_keys
RUN printf '%s\\n' 'PermitRootLogin yes' 'PasswordAuthentication yes' 'KbdInteractiveAuthentication no' 'PubkeyAuthentication yes' 'StrictModes yes' 'AllowUsers root' 'AllowTcpForwarding no' 'AllowAgentForwarding no' 'X11Forwarding no' 'UseDNS no' 'Subsystem sftp internal-sftp' > /etc/ssh/sshd_config
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
''')
        cls.diagnostics = ROOT / '.local/integration' / cls.token
        cls.diagnostics.mkdir(parents=True, exist_ok=True)
        cls.addClassCleanup(cls.cleanup_services)
        # Preserve build diagnostics without filling the test output or hiding errors.
        with open(cls.diagnostics / 'image-build.log', 'w') as output:
            result = subprocess.run(['docker', '--host', cls.docker_endpoint, 'build', '--label', 'io.ctrl.integration.run=' + cls.token, '-t', cls.image, str(build)], stdout=output,
                                    stderr=subprocess.STDOUT, timeout=300, env=cls.docker_env)
        if result.returncode:
            raise RuntimeError('Fixture image build failed; inspect ' + str(cls.diagnostics / 'image-build.log'))
        checked('docker', 'network', 'create', '--label', 'io.ctrl.integration.run=' + cls.token, cls.network)
        cls.container = checked('docker', 'run', '-d', '--rm', '--name', cls.container_name,
                                '--label', 'io.ctrl.integration.run=' + cls.token, '--network', cls.network,
                                '--cap-drop=ALL', '--cap-add=SETUID', '--cap-add=SETGID', '--cap-add=SYS_CHROOT', '--cap-add=NET_BIND_SERVICE',
                                '--security-opt=no-new-privileges', '-p', '127.0.0.1::22', cls.image)
        address = checked('docker', 'port', cls.container, '22/tcp').splitlines()[0]
        cls.port = int(address.rsplit(':', 1)[1])
        host_key = checked('docker', 'exec', cls.container, 'cat', '/etc/ssh/ssh_host_ed25519_key.pub')
        cls.host_key = ' '.join(host_key.split()[:2])
        cls.known_hosts = cls.base / 'known_hosts'
        cls.known_hosts.write_text('[127.0.0.1]:' + str(cls.port) + ' ' + cls.host_key + '\n')
        cls.ssh = shutil.which('ssh')
        cls.ssh_options = ['-F', '/dev/null', '-o', 'UserKnownHostsFile=' + str(cls.known_hosts),
                           '-o', 'GlobalKnownHostsFile=/dev/null', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=2',
                           '-o', 'StrictHostKeyChecking=yes', '-o', 'HostKeyAlgorithms=ssh-ed25519',
                           '-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none',
                           '-i', str(cls.key), '-p', str(cls.port)]
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            result = run(cls.ssh, *cls.ssh_options, 'root@127.0.0.1', 'true', timeout=5)
            if result.returncode == 0:
                break
            time.sleep(.2)
        else:
            raise RuntimeError('Disposable sshd did not become ready: ' + result.stderr)

    @classmethod
    def cleanup_services(cls):
        identifier = cls.container or cls.container_name
        result = run('docker', 'logs', identifier)
        (cls.diagnostics / 'sshd.log').write_text(result.stdout + result.stderr)
        errors = []
        for kind, identifier in [('container', identifier), ('network', cls.network), ('image', cls.image)]:
            inspection = run('docker', kind, 'inspect', identifier)
            if inspection.returncode:
                continue  # It was never created, or --rm already removed it.
            data = json.loads(inspection.stdout)[0]
            labels = data.get('Labels') if kind == 'network' else data.get('Config', {}).get('Labels')
            if (labels or {}).get('io.ctrl.integration.run') != cls.token:
                errors.append('Refusing to remove resource without this run label: ' + identifier)
                continue
            args = ['docker', 'rm', '-f', identifier] if kind == 'container' else ['docker', kind, 'rm', identifier]
            removal = run(*args)
            if removal.returncode or run('docker', kind, 'inspect', identifier).returncode == 0:
                errors.append('Cleanup failed for ' + identifier + ': ' + removal.stderr)
        if errors:
            raise RuntimeError('\n'.join(errors))

    def setUp(self):
        self.project = self.base / self._testMethodName
        self.project.mkdir()
        self.bin = self.project / 'bin'
        self.bin.mkdir()
        docker_adapter(self.bin, self.docker, self.docker_endpoint)
        self.ssh_capture = self.project / 'ssh-argv.jsonl'
        # This is a configuration adapter around the REAL SSH executable. It
        # isolates known_hosts and SSH config; it does not simulate transport.
        shim = self.bin / 'ssh'
        shim.write_text('#!' + sys.executable + '\nimport json,os,sys\n' +
                        f'with open({str(self.ssh_capture)!r},"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n' +
                        f'os.execv({self.ssh!r},[{self.ssh!r},"-F","/dev/null","-o",{("UserKnownHostsFile="+str(self.known_hosts))!r},"-o","GlobalKnownHostsFile=/dev/null","-o","HostKeyAlgorithms=ssh-ed25519","-o","IdentitiesOnly=yes","-o","IdentityAgent=none"]+sys.argv[1:])\n')
        shim.chmod(0o755)
        self.env = dict(self.docker_env, PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        self.remote = "/tmp/ctrl test's " + uuid.uuid4().hex[:8]
        checked('docker', 'exec', self.container, 'mkdir', '-p', self.remote)
        self.config = self.project / 'ctrl.yaml'
        self.data = dict(version=1, project='integration', operations={}, targets={
            'sandbox': dict(host='127.0.0.1', user='root', port=self.port, key=str(self.key), cwd=self.remote)})
        self.write_config()

    def write_config(self):
        self.config.write_text(json.dumps(self.data))

    def operation(self, body, tools=None, env=None):
        (self.project / 'probe.sh').write_text('#!/usr/bin/env bash\nset -euo pipefail\n' + body + '\n')
        contract = dict(version=1, description='Disposable SSH probe', effects='read', execution='target',
                        tools=tools or [], env=env or [], parameters=[dict(name='value', type='string', default='hello')])
        (self.project / 'probe.yaml').write_text(json.dumps(contract))
        self.data['operations']['probe'] = './probe.sh'
        self.write_config()

    def ctrl(self, *args, packaged=True, timeout=45):
        return run(str(ROOT / ('dist/ctrl' if packaged else 'ctrl.sh')), '--config', str(self.config),
                   *args, env=self.env, cwd=self.project, timeout=timeout)

    def records(self):
        return [json.loads(line) for line in (self.project / '.local/ctrl/audit.jsonl').read_text().splitlines()]

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_real_ssh_round_trip_quotes_and_declared_secret_environment(self):
        self.operation('''python3 - <<'PYCODE'
import json,os
print(json.dumps(dict(value=os.environ['CTRL_PARAM_VALUE'], secret=os.environ['APP_TOKEN'],
                     cwd=os.getcwd(), undeclared='UNDECLARED_TOKEN' in os.environ)))
PYCODE''', tools=['python3'], env=['APP_TOKEN'])
        self.env.update(APP_TOKEN='temporary-test-secret', UNDECLARED_TOKEN='must-not-travel')
        payload = "$(touch escaped) 'single' \"double\" ; `touch escaped2`\nnext line"
        result = self.ctrl('probe', '--on', 'sandbox', '--', payload)
        self.assert_ok(result)
        response = json.loads(result.stdout)
        self.assertEqual(response, dict(value=payload, secret='temporary-test-secret', cwd=self.remote, undeclared=False))
        self.assertNotIn('temporary-test-secret', self.ssh_capture.read_text())
        self.assertNotIn('temporary-test-secret', json.dumps(self.records()))
        self.assertNotEqual(run('docker', 'exec', self.container, 'test', '-e', self.remote + '/escaped').returncode, 0)
        self.assertEqual(self.records()[-1]['exit_code'], 0)

    def test_real_ssh_preserves_remote_failure_status(self):
        self.operation('printf "intentional failure\\n" >&2\nexit 23')
        result = self.ctrl('probe', '--on', 'sandbox', packaged=False)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(self.records()[-1]['exit_code'], 23)
        self.assertEqual(self.records()[-1]['outcome'], 'failed')

    def test_remote_missing_dependency_prevents_script_side_effects(self):
        self.operation('touch should-not-exist', tools=['ctrl_missing_integration_tool'])
        result = self.ctrl('probe', '--on', 'sandbox')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(run('docker', 'exec', self.container, 'test', '-e', self.remote + '/should-not-exist').returncode, 0)
        self.assertNotIn('executing', [r['event'] for r in self.records()])

    def test_real_host_key_mismatch_fails_before_remote_operation(self):
        self.operation('touch should-not-exist')
        correct = self.known_hosts.read_text()
        wrong = ' '.join(self.key.with_suffix('.pub').read_text().split()[:2])
        try:
            self.known_hosts.write_text('[127.0.0.1]:' + str(self.port) + ' ' + wrong + '\n')
            result = self.ctrl('probe', '--on', 'sandbox')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('HOST IDENTIFICATION HAS CHANGED', result.stderr)
            self.assertNotEqual(run('docker', 'exec', self.container, 'test', '-e', self.remote + '/should-not-exist').returncode, 0)
            self.assertNotIn('executing', [r['event'] for r in self.records()])
        finally:
            self.known_hosts.write_text(correct)

    def test_plan_and_check_do_not_execute_real_remote_body(self):
        self.operation('touch should-not-exist')
        self.assert_ok(self.ctrl('probe', '--on', 'sandbox', '--dry-run'))
        self.assertFalse(self.ssh_capture.exists(), 'Plan unexpectedly connected to SSH')
        self.assert_ok(self.ctrl('check', 'probe', '--on', 'sandbox'))
        self.assertTrue(self.ssh_capture.exists(), 'Preflight did not use real SSH')
        self.assertNotEqual(run('docker', 'exec', self.container, 'test', '-e', self.remote + '/should-not-exist').returncode, 0)

    def test_real_copy_upload_download_and_file_contents(self):
        self.data['operations']['cp'] = 'host/copy'
        self.write_config()
        source = self.project / "secret 'sample'.bin"
        contents = b'copy-test-secret\x00binary\n'
        source.write_bytes(contents)
        source.chmod(0o600)
        remote = self.remote + "/file 'with spaces'.bin"
        self.assert_ok(self.ctrl('cp', str(source), 'sandbox:' + remote, '--yes'))
        received = self.project / 'download.bin'
        self.assert_ok(self.ctrl('cp', 'sandbox:' + remote, str(received), '--yes'))
        self.assertEqual(received.read_bytes(), contents)
        journal = self.records()
        self.assertNotIn('copy-test-secret', json.dumps(journal))
        finished = [r for r in journal if r['event'] == 'finished']
        self.assertEqual(len(finished), 4)
        self.assertTrue(all(r['exit_code'] == 0 for r in finished))

    def test_real_copy_target_relay_does_not_need_remote_to_remote_trust(self):
        self.data['operations']['cp'] = 'host/copy'
        self.data['targets']['other'] = dict(self.data['targets']['sandbox'])
        self.write_config()
        source = self.project / 'original.txt'
        source.write_text('relay through the controller')
        src = self.remote + '/original.txt'
        dst = self.remote + '/relayed.txt'
        self.assert_ok(self.ctrl('cp', str(source), 'sandbox:' + src, '--yes'))
        self.assert_ok(self.ctrl('cp', 'sandbox:' + src, 'other:' + dst, '--yes'))
        self.assertEqual(checked('docker', 'exec', self.container, 'cat', dst), source.read_text())
        finished = [r for r in self.records() if r['event'] == 'finished']
        self.assertEqual([r['target'] for r in finished[-3:]], ['sandbox', 'other', 'local'])
        self.assertEqual(finished[-3]['parent_run_id'], finished[-1]['run_id'])
        self.assertEqual(finished[-2]['parent_run_id'], finished[-1]['run_id'])

    def test_real_copy_recursive_directory_requires_explicit_flag(self):
        self.data['operations']['cp'] = 'host/copy'
        self.write_config()
        source = self.project / 'folder'
        (source / 'nested').mkdir(parents=True)
        (source / 'nested/data.txt').write_text('directory data')
        remote = self.remote + '/received-folder'
        self.assert_ok(self.ctrl('cp', str(source), 'sandbox:' + remote, '--recursive', '--yes'))
        received = self.project / 'downloaded-folder'
        self.assert_ok(self.ctrl('cp', 'sandbox:' + remote, str(received), '--recursive', '--yes'))
        self.assertEqual((received / 'nested/data.txt').read_text(), 'directory data')

    def test_real_rsync_upload_and_explicit_delete_with_spaced_paths(self):
        # Run the Linux packaged controller inside the isolated fixture so this
        # test uses rsync 3 without replacing macOS's system rsync or SSH files.
        client = self.project / 'linux-client'
        (client / 'source').mkdir(parents=True)
        (client / 'bin').mkdir()
        payload = b'bytes\x00with binary data\n'
        filename = "report 'draft'.bin"
        (client / 'source' / filename).write_bytes(payload)
        destination = self.remote + '/destination with spaces/'
        location = '/tmp/client-' + uuid.uuid4().hex[:8]
        config = dict(version=1, project='rsync-integration', operations={'sync': 'host/sync'}, targets={
            'sandbox': dict(host='127.0.0.1', port=22, user='root', key=location + '/client_key', cwd='/tmp')})
        (client / 'ctrl.yaml').write_text(json.dumps(config))
        shutil.copy(ROOT / 'dist/ctrl', client / 'ctrl')
        shutil.copy(self.key, client / 'client_key')
        (client / 'known_hosts').write_text('127.0.0.1 ' + self.host_key + '\n')
        shim = client / 'bin/ssh'
        shim.write_text('#!/usr/bin/env python3\nimport os,sys\n' +
                        'os.execv("/usr/bin/ssh",["/usr/bin/ssh","-F","/dev/null","-o","GlobalKnownHostsFile=/dev/null","-o",' +
                        repr('UserKnownHostsFile=' + location + '/known_hosts') + ',"-o","HostKeyAlgorithms=ssh-ed25519","-o","IdentitiesOnly=yes","-o","IdentityAgent=none"]+sys.argv[1:])\n')
        shim.chmod(0o755)
        checked('docker', 'exec', self.container, 'mkdir', '-p', location, destination)
        # Seed fixture files through stdin as the container user. docker cp can
        # preserve host ownership on Desktop; adding CHOWN/DAC_OVERRIDE caps just
        # to repair those files would weaken the disposable server unnecessarily.
        files = {str(path.relative_to(client)): dict(data=base64.b64encode(path.read_bytes()).decode(), mode=path.stat().st_mode & 0o777)
                 for path in client.rglob('*') if path.is_file()}
        seed = """import base64,json,sys
from pathlib import Path
root=Path(sys.argv[1])
for name,item in json.load(sys.stdin).items():
    path=root/name
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_bytes(base64.b64decode(item['data']))
    path.chmod(item['mode'])
"""
        self.assert_ok(run('docker', 'exec', '-i', self.container, 'python3', '-c', seed, location,
                           input=json.dumps(files)))
        command = ['docker', 'exec', '-e', 'PATH=' + location + '/bin:/usr/local/bin:/usr/bin:/bin', self.container,
                   'python3', location + '/ctrl', '--config', location + '/ctrl.yaml', 'sync', location + '/source/', destination,
                   '--on', 'sandbox', '--yes']
        self.assert_ok(run(*command))
        encoded = checked('docker', 'exec', self.container, 'python3', '-c',
                          'import base64,sys;print(base64.b64encode(open(sys.argv[1],"rb").read()).decode())', destination + filename)
        self.assertEqual(base64.b64decode(encoded), payload)
        checked('docker', 'exec', self.container, 'touch', destination + 'obsolete')
        self.assert_ok(run(*command))
        self.assertEqual(run('docker', 'exec', self.container, 'test', '-e', destination + 'obsolete').returncode, 0)
        self.assert_ok(run(*command, '--delete'))
        self.assertNotEqual(run('docker', 'exec', self.container, 'test', '-e', destination + 'obsolete').returncode, 0)
        journal = checked('docker', 'exec', self.container, 'cat', location + '/.local/ctrl/audit.jsonl')
        finished = [r for r in map(json.loads, journal.splitlines()) if r['event'] == 'finished']
        self.assertEqual([r['exit_code'] for r in finished], [0, 0, 0])

    def prepare_compose(self):
        example = self.project / 'application'
        shutil.copytree(ROOT / 'examples/compose-app', example, ignore=shutil.ignore_patterns('.local', '__pycache__'))
        self.project = example
        self.config = example / 'ctrl.yaml'
        self.data = json.loads(checked('yq', '-o=json', '.', str(self.config)))
        self.compose_project = 'ctrl-it-' + uuid.uuid4().hex[:12]
        self.tag = 'ctrl-it-' + uuid.uuid4().hex[:12]
        self.app_image = 'example/api:' + self.tag
        self.addCleanup(self.cleanup_compose)
        for name, entry in self.data['operations'].items():
            if isinstance(entry, str):
                entry = {'script': entry} if entry.startswith('./') else {'uses': entry}
                self.data['operations'][name] = entry
            entry.setdefault('environment', {})['COMPOSE_PROJECT_NAME'] = self.compose_project
        compose = {'services': {'api': {'image': 'example/api:${APP_TAG:-review}', 'ports': ['127.0.0.1::8000']}},
                   'networks': {'default': {}}}
        (example / 'docker-compose.yml').write_text(json.dumps(compose))
        dockerfile = example / 'api/Dockerfile'
        dockerfile.write_text(dockerfile.read_text().replace('FROM python:3.12-alpine', 'FROM ' + self.image))
        self.write_config()

    def cleanup_compose(self):
        result = run('docker', 'compose', '-p', self.compose_project, '-f', str(self.project / 'docker-compose.yml'),
                     'down', '--remove-orphans', timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        containers = checked('docker', 'ps', '-aq', '--filter', 'label=com.docker.compose.project=' + self.compose_project)
        networks = checked('docker', 'network', 'ls', '-q', '--filter', 'label=com.docker.compose.project=' + self.compose_project)
        self.assertFalse(containers, 'Compose cleanup left test containers')
        self.assertFalse(networks, 'Compose cleanup left test networks')
        if run('docker', 'image', 'inspect', self.app_image).returncode == 0:
            checked('docker', 'image', 'rm', self.app_image)
            self.assertNotEqual(run('docker', 'image', 'inspect', self.app_image).returncode, 0)

    def http(self, port):
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=.5)
        try:
            connection.request('GET', '/health')
            response = connection.getresponse()
            return response.status, response.read().decode()
        finally:
            connection.close()

    def test_real_docker_build_compose_start_health_logs_and_stop(self):
        self.prepare_compose()
        self.assert_ok(self.ctrl('build', 'api', '--tag', self.tag, '--yes', timeout=120))
        self.assert_ok(self.ctrl('start', '--tag', self.tag, '--yes', timeout=60))
        cid = checked('docker', 'compose', '-p', self.compose_project, '-f', str(self.project / 'docker-compose.yml'), 'ps', '-q', 'api')
        port = int(checked('docker', 'port', cid, '8000/tcp').splitlines()[0].rsplit(':', 1)[1])
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                if self.http(port) == (200, 'ok\n'):
                    break
            except (OSError, http.client.HTTPException):
                pass
            time.sleep(.1)
        else:
            self.fail('Real Compose service did not become healthy')
        self.data['operations']['smoke']['environment']['APP_URL'] = 'http://127.0.0.1:' + str(port)
        self.write_config()
        self.assert_ok(self.ctrl('smoke'))
        status = self.ctrl('status')
        self.assert_ok(status)
        self.assertIn('api', status.stdout)
        logs = self.ctrl('logs', 'api', '--lines', '20')
        self.assert_ok(logs)
        self.assertIn('GET /health', logs.stdout + logs.stderr)
        self.assert_ok(self.ctrl('stop', '--yes'))
        self.assertNotEqual(run('docker', 'inspect', cid).returncode, 0)
        self.assertTrue(all(r['exit_code'] == 0 for r in self.records() if r['event'] == 'finished'))

    def test_real_docker_build_failure_is_preserved_in_audit(self):
        context = self.project / 'bad-build'
        context.mkdir()
        (context / 'Dockerfile').write_text('FROM scratch\nRUN ["/missing-command"]\n')
        image = 'ctrl-integration-bad:' + uuid.uuid4().hex[:12]
        self.data['operations']['build'] = 'docker/build'
        self.write_config()
        self.addCleanup(lambda: run('docker', 'image', 'rm', image))
        result = self.ctrl('build', image, '--context', './bad-build', '--dockerfile', 'bad-build/Dockerfile', '--yes', timeout=90)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.records()[-1]['exit_code'], result.returncode)
        self.assertEqual(self.records()[-1]['outcome'], 'failed')
        self.assertNotEqual(run('docker', 'image', 'inspect', image).returncode, 0)


    def password_target(self):
        self.data['targets']['sandbox']['password_env'] = 'FIXTURE_SSH_PASSWORD'
        self.env['FIXTURE_SSH_PASSWORD'] = 'ctrl-fixture-password'
        self.write_config()

    def test_real_password_ssh_and_sftp_copy_keep_credentials_private(self):
        self.operation('printf "%s" "${FIXTURE_SSH_PASSWORD-unset}"')
        self.password_target()
        self.data['operations']['cp'] = 'host/copy'
        self.write_config()
        result = self.ctrl('probe', '--on', 'sandbox')
        self.assert_ok(result)
        self.assertEqual(result.stdout, 'unset')
        source = self.project / 'password copy.bin'
        source.write_bytes(b'copy via password\x00\n')
        self.assert_ok(self.ctrl('cp', str(source), 'sandbox:' + self.remote + '/password.bin', '--yes'))
        destination = self.project / 'download.bin'
        self.assert_ok(self.ctrl('cp', 'sandbox:' + self.remote + '/password.bin', str(destination), '--yes'))
        self.assertEqual(destination.read_bytes(), source.read_bytes())
        self.assertNotIn(self.env['FIXTURE_SSH_PASSWORD'], self.ssh_capture.read_text() + json.dumps(self.records()))

    def test_real_password_failure_does_not_execute_remote_script(self):
        self.operation('touch password-should-not-execute')
        self.password_target()
        self.env['FIXTURE_SSH_PASSWORD'] = 'wrong-fixture-password'
        result = self.ctrl('probe', '--on', 'sandbox')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(run('docker', 'exec', self.container, 'test', '-e', self.remote + '/password-should-not-execute').returncode, 0)
        self.assertNotIn('wrong-fixture-password', result.stdout + result.stderr + json.dumps(self.records()))

    def test_real_key_setup_preserves_keys_is_idempotent_and_retains_password(self):
        self.password_target()
        self.data['operations']['ssh-key-setup'] = 'host/ssh-key-setup'
        self.write_config()
        key = self.project / 'new key'
        checked('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key))
        before = checked('docker', 'exec', self.container, 'cat', '/root/.ssh/authorized_keys')
        result = self.ctrl('ssh-key-setup', '--on', 'sandbox', '--key', str(key), '--yes')
        self.assert_ok(result)
        self.assertIn('Key-only login verified', result.stdout)
        after = checked('docker', 'exec', self.container, 'cat', '/root/.ssh/authorized_keys')
        self.assertIn(before, after)
        self.assertEqual(after.count(key.with_suffix('.pub').read_text().strip()), 1)
        backups = checked('docker', 'exec', self.container, 'sh', '-c', 'cat /root/.ssh/authorized_keys.ctrl-backup.*')
        self.assertIn(before, backups)
        self.assert_ok(self.ctrl('ssh-key-setup', '--on', 'sandbox', '--key', str(key), '--yes'))
        self.assertEqual(after, checked('docker', 'exec', self.container, 'cat', '/root/.ssh/authorized_keys'))
        self.assertEqual(json.loads(self.config.read_text())['targets']['sandbox']['password_env'], 'FIXTURE_SSH_PASSWORD')
        self.operation('printf password-still-works')
        result = self.ctrl('probe', '--on', 'sandbox')
        self.assert_ok(result)
        self.assertEqual(result.stdout, 'password-still-works')
        self.assertNotIn(self.env['FIXTURE_SSH_PASSWORD'], self.ssh_capture.read_text() + json.dumps(self.records()))

    def test_real_key_setup_verification_failure_reports_key_added_and_preserves_password(self):
        self.password_target()
        self.data['operations']['ssh-key-setup'] = 'host/ssh-key-setup'
        self.write_config()
        key = self.project / 'wrong pair'
        other = self.project / 'other pair'
        for path in (key, other):
            checked('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(path))
        shutil.copy2(other.with_suffix('.pub'), key.with_suffix('.pub'))
        result = self.ctrl('ssh-key-setup', '--on', 'sandbox', '--key', str(key), '--yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Key was authorized, but key-only verification failed', result.stderr)
        self.operation('printf password-still-works')
        self.assert_ok(self.ctrl('probe', '--on', 'sandbox'))
