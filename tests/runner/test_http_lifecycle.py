"""Real localhost integration for example servers: no Docker or external network."""
import http.client
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]


class HttpLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        probe = socket.socket()
        try:
            probe.bind(('127.0.0.1', 0))
        except PermissionError:
            if os.environ.get('CI', '').lower() == 'true':
                raise RuntimeError('CI must permit loopback for the HTTP lifecycle tests')
            raise unittest.SkipTest('Execution sandbox blocks loopback; rerun this suite with local socket permission')
        finally:
            probe.close()
        subprocess.run(['bash', str(ROOT / 'build.sh')], check=True, capture_output=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ctrl-http-test-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.child = None
        self.log = None
        self.addCleanup(self.stop)

    def prepare(self, name, port):
        self.project = self.base / name
        shutil.copytree(ROOT / 'examples' / name, self.project,
                        ignore=shutil.ignore_patterns('.local', '__pycache__', '*.pyc'))
        contract = self.project / 'scripts/start.yaml'
        data = json.loads(subprocess.run(['yq', '-o=json', '.', str(contract)], check=True,
                                        capture_output=True, text=True).stdout)
        # Retain the example's parameter type, but allocate a test-approved free
        # port rather than requiring fixed developer ports to be available.
        data['parameters'][0]['choices'] = [str(port)]
        data['parameters'][0]['default'] = str(port)
        contract.write_text(json.dumps(data))
        self.port = port

    def command(self, packaged=False):
        return [str(ROOT / ('dist/ctrl' if packaged else 'ctrl.sh')),
                '--config', str(self.project / 'ctrl.yaml'), 'start', '--port', str(self.port), '--yes']

    def request(self, path):
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=.5)
        try:
            connection.request('GET', path)
            response = connection.getresponse()
            return response.status, response.read().decode()
        finally:
            connection.close()

    def start(self, name, packaged=False):
        with socket.socket() as port:
            port.bind(('127.0.0.1', 0))
            self.prepare(name, port.getsockname()[1])
        self.log = open(self.base / 'server.log', 'w+')
        self.child = subprocess.Popen(self.command(packaged), cwd=self.project, stdout=self.log, stderr=self.log)
        deadline = time.monotonic() + 20
        announcement = 'Listening on http://127.0.0.1:' + str(self.port)
        last_error = 'server has not announced readiness'
        while time.monotonic() < deadline:
            output = (self.base / 'server.log').read_text()
            if self.child.poll() is not None:
                self.fail('Server exited before readiness:\n' + output)
            # Do not probe an unbound ephemeral destination: on macOS a client
            # can acquire that same source port and self-connect before bind.
            # Both real apps announce only after their listen() has succeeded.
            if announcement in output:
                try:
                    response = self.request('/health')
                    if response == (200, 'ok'):
                        return
                    last_error = repr(response)
                except (OSError, http.client.HTTPException) as exc:
                    last_error = repr(exc)
            time.sleep(.03)
        self.fail('Server did not become ready: ' + last_error + '\n' + (self.base / 'server.log').read_text())

    def stop(self):
        if self.child and self.child.poll() is None:
            self.child.send_signal(signal.SIGTERM)
            try:
                self.child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.wait()
        if self.log:
            self.log.close()
            self.log = None

    def records(self):
        return [json.loads(line) for line in (self.project / '.local/ctrl/audit.jsonl').read_text().splitlines()]

    def assert_lifecycle(self):
        self.assertEqual(self.request('/'), (200, 'Hello, world!'))
        self.assertEqual(self.request('/missing')[0], 404)
        self.assertEqual(self.request('/health'), (200, 'ok'))
        self.child.send_signal(signal.SIGTERM)
        self.child.wait(timeout=5)
        self.assertEqual(self.child.returncode, 130)
        self.assertEqual(self.records()[-1]['outcome'], 'cancelled')
        with self.assertRaises(OSError):
            self.request('/health')

    def test_python_server_real_requests_and_cancellation(self):
        self.start('python-app')
        self.assert_lifecycle()

    @unittest.skipUnless(shutil.which('node'), 'Node.js is an optional example prerequisite')
    def test_packaged_node_server_real_requests_and_cancellation(self):
        self.start('node-app', packaged=True)
        self.assert_lifecycle()

    def assert_port_collision(self, name, packaged=False):
        with socket.socket() as occupied:
            occupied.bind(('127.0.0.1', 0))
            occupied.listen(1)
            self.prepare(name, occupied.getsockname()[1])
            result = subprocess.run(self.command(packaged), cwd=self.project, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.records()[-1]['exit_code'], result.returncode)
        self.assertEqual(self.records()[-1]['outcome'], 'failed')

    def test_python_port_collision_is_not_reported_as_success(self):
        self.assert_port_collision('python-app')

    @unittest.skipUnless(shutil.which('node'), 'Node.js is an optional example prerequisite')
    def test_node_port_collision_is_not_reported_as_success(self):
        self.assert_port_collision('node-app', packaged=True)
