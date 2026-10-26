"""Public examples must work independently of private repositories or credentials."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / 'examples/catalog.json').read_text())


class ExampleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(['bash', str(ROOT / 'build.sh')], check=True, capture_output=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ctrl-examples-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        self.capture = self.base / 'commands.jsonl'

    def use_example(self, name):
        self.project = self.base / name
        shutil.copytree(ROOT / 'examples' / name, self.project,
                        ignore=shutil.ignore_patterns('.local', '__pycache__', '*.pyc'))
        self.config = self.project / 'ctrl.yaml'

    def run_ctrl(self, *args, packaged=False):
        executable = ROOT / ('dist/ctrl' if packaged else 'ctrl.sh')
        return subprocess.run([str(executable), '--config', str(self.config), *args], cwd=self.project,
                              env=self.env, text=True, capture_output=True, timeout=30)

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def fake(self, name, body):
        path = self.bin / name
        path.write_text('#!' + sys.executable + '\n' + body)
        path.chmod(0o755)

    def capture_tool(self, name):
        self.fake(name, 'import sys,json\n' +
                  f'with open({str(self.capture)!r},"a") as stream: stream.write(json.dumps(sys.argv[1:])+"\\n")\n')

    def test_catalog_discovery_matches_source_and_executable(self):
        for executable in (ROOT / 'ctrl.sh', ROOT / 'dist/ctrl'):
            result = subprocess.run([str(executable), 'help', 'examples', '--json'], cwd=self.base,
                                    env=self.env, capture_output=True, text=True)
            self.assert_ok(result)
            self.assertEqual(json.loads(result.stdout), CATALOG)
        self.assertEqual({e['path'] for e in CATALOG},
                         {'scripts-only', 'python-app', 'node-app', 'java-maven', 'compose-app', 'systemd-service'})

    def test_every_public_example_has_valid_contracts_and_help(self):
        for entry in CATALOG:
            with self.subTest(example=entry['path']):
                self.use_example(entry['path'])
                self.assertTrue((self.project / 'README.md').is_file())
                for packaged in (False, True):
                    self.assert_ok(self.run_ctrl('check', packaged=packaged))
                    discovery = self.run_ctrl('help', '--json', packaged=packaged)
                    self.assert_ok(discovery)
                    for operation in json.loads(discovery.stdout)['operations']:
                        self.assert_ok(self.run_ctrl('help', operation['name'], '--json', packaged=packaged))
                        self.assert_ok(self.run_ctrl('help', operation['name'], '--source', packaged=packaged))

    def test_catalog_first_commands_are_executable_or_nonexecuting_plans(self):
        for entry in CATALOG:
            if entry['path'] == 'node-app' and not shutil.which('node'):
                continue
            with self.subTest(example=entry['path']):
                self.use_example(entry['path'])
                result = self.run_ctrl(*shlex.split(entry['first']), packaged=True)
                self.assert_ok(result)

    def test_scripts_only_parameter_contract_and_actual_report(self):
        self.use_example('scripts-only')
        result = self.run_ctrl('report', '--format', 'json')
        self.assert_ok(result)
        report = json.loads(result.stdout)
        self.assertEqual(report['project'], 'scripts-demo')
        self.assertIn('ctrl.yaml', report['files'])
        result = self.run_ctrl('report', '--format', 'xml')
        self.assertNotEqual(result.returncode, 0)
        records = [json.loads(line) for line in (self.project / '.local/ctrl/audit.jsonl').read_text().splitlines()]
        self.assertEqual(records[-1]['outcome'], 'rejected')

    def test_python_application_tests_and_real_build_artifact(self):
        self.use_example('python-app')
        self.assert_ok(self.run_ctrl('test'))
        self.assertFalse((self.project / 'app/__pycache__').exists())
        self.assert_ok(self.run_ctrl('build', '--yes'))
        archive = self.project / '.local/build/demo.pyz'
        self.assertTrue(zipfile.is_zipfile(archive))
        result = subprocess.run([sys.executable, str(archive), '--help'], capture_output=True, text=True)
        self.assert_ok(result)
        self.assertIn('--port', result.stdout)

    @unittest.skipUnless(shutil.which('node'), 'Node.js is an optional example prerequisite')
    def test_node_application_tests_and_real_build_artifact(self):
        self.use_example('node-app')
        self.assert_ok(self.run_ctrl('test'))
        self.assert_ok(self.run_ctrl('build', '--yes'))
        self.assertEqual((self.project / '.local/build/app.js').read_bytes(), (self.project / 'app.js').read_bytes())
        result = subprocess.run(['node', '-e', 'const assert=require("assert");const app=require("./.local/build/app");assert.strictEqual(app.greeting("Ada"),"Hello, Ada!");'],
                                cwd=self.project, capture_output=True, text=True)
        self.assert_ok(result)

    def test_java_tests_execute_with_available_jdk(self):
        import re
        if not shutil.which('javac') or not shutil.which('java'):
            self.skipTest('JDK is an optional example prerequisite')
        version = subprocess.run(['javac', '-version'], capture_output=True, text=True)
        match = re.search(r'javac (\d+)', version.stdout + version.stderr)
        if version.returncode or not match or int(match.group(1)) < 17:
            self.skipTest('JDK 17+ is an optional example prerequisite')
        self.use_example('java-maven')
        result = self.run_ctrl('test', '--yes')
        self.assert_ok(result)
        self.assertIn('2 greeting tests passed', result.stdout)
        self.assertTrue((self.project / '.local/test/demo/App.class').is_file())

    def test_java_build_script_and_typed_jar_invocation(self):
        self.use_example('java-maven')
        self.capture_tool('mvn')
        self.capture_tool('java')
        self.assert_ok(self.run_ctrl('build', '--yes'))
        commands = [json.loads(line) for line in self.capture.read_text().splitlines()]
        self.assertEqual(commands[0][-2:], ['-DskipTests', 'package'])
        self.assertIn('-Dmaven.repo.local=' + str(self.project.resolve()) + '/.local/m2', commands[0])
        artifact = self.project / '.local/build/demo.jar'
        artifact.parent.mkdir(parents=True, exist_ok=True)
        artifact.write_bytes(b'test fixture; java is faked')
        self.assert_ok(self.run_ctrl('greet', 'Ada'))
        commands = [json.loads(line) for line in self.capture.read_text().splitlines()]
        self.assertEqual(commands[-1], ['-jar', str(artifact.resolve()), 'Ada'])
        self.assertNotEqual(self.run_ctrl('greet', 'bad;command').returncode, 0)

    def test_local_server_plans_and_port_restrictions(self):
        for name, port in [('python-app', '8080'), ('node-app', '3000')]:
            self.use_example(name)
            self.assert_ok(self.run_ctrl('start', '--port', port, '--dry-run'))
            self.assertNotEqual(self.run_ctrl('start', '--port', '22', '--dry-run').returncode, 0)

    def test_compose_workflow_uses_only_its_local_sample(self):
        self.use_example('compose-app')
        self.capture_tool('docker')
        self.capture_tool('curl')
        for args in [('build', 'api', '--tag', 'review', '--yes'), ('start', '--yes'),
                     ('status',), ('smoke',), ('logs', 'api', '--lines', '20'), ('stop', '--yes')]:
            self.assert_ok(self.run_ctrl(*args))
        commands = [json.loads(line) for line in self.capture.read_text().splitlines()]
        self.assertEqual(commands[0][-1], str((self.project / 'api').resolve()))
        self.assertEqual(commands[1], ['compose', '-f', 'docker-compose.yml', 'up', '-d', '--no-build', 'api'])
        self.assertIn('http://127.0.0.1:8080/health', commands[3])
        self.assertEqual(commands[-1], ['compose', '-f', 'docker-compose.yml', 'down'])
        self.assertTrue((self.project / 'api/Dockerfile').is_file())

    def test_systemd_operations_are_remote_and_unit_allowlisted(self):
        self.use_example('systemd-service')
        data = json.loads(subprocess.run(['yq', '-o=json', '.', str(self.config)],
                                        check=True, capture_output=True, text=True).stdout)
        data['targets']['demo']['cwd'] = str(self.project)
        self.config.write_text(json.dumps(data))
        self.env['DEMO_HOST'] = 'demo.example.invalid'
        self.capture_tool('systemctl')
        self.fake('sudo', 'import subprocess,sys\nraise SystemExit(subprocess.call(sys.argv[2:]))\n')
        self.fake('ssh', 'import subprocess,sys\nbody=sys.stdin.read()\nraise SystemExit(subprocess.run(["bash","--noprofile","--norc","-s"],input=body,text=True).returncode)\n')
        self.assert_ok(self.run_ctrl('status', '--on', 'demo'))
        self.assert_ok(self.run_ctrl('restart', '--on', 'demo', '--yes'))
        commands = [json.loads(line) for line in self.capture.read_text().splitlines()]
        self.assertEqual(commands, [['status', '--no-pager', '--', 'demo-web.service'], ['restart', '--', 'demo-web.service']])
        self.capture.unlink()
        self.assertNotEqual(self.run_ctrl('restart', '--yes').returncode, 0)
        self.assertNotEqual(self.run_ctrl('restart', 'other.service', '--on', 'demo', '--yes').returncode, 0)
        self.assertFalse(self.capture.exists())
