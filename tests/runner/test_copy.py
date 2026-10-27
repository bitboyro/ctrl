"""The public cp operation retains actual file-copy capabilities through one runner."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CopyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(['bash', str(ROOT / 'build.sh')], check=True, capture_output=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ctrl-copy-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.capture = self.base / 'scp.jsonl'
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        self.config = self.base / 'ctrl.yaml'
        self.config.write_text(json.dumps(dict(version=1, project='copy-test', operations={'cp': 'host/copy'}, targets={
            'demo': dict(host='demo.example.invalid', user='deploy', port=2200, key=str(self.base / 'key with spaces'), cwd='/srv/app'),
            'other': dict(host='other.example.invalid', user='other', port=2222, cwd='/srv/other')})))
        self.source = self.base / "file 'with spaces'.bin"
        self.source.write_bytes(b'private-test-value\x00\n')

    def run_ctrl(self, *args, packaged=False):
        return subprocess.run([str(ROOT / ('dist/ctrl' if packaged else 'ctrl.sh')), '--config', str(self.config),
                               'cp', *map(str,args)], cwd=self.base, env=self.env, capture_output=True, text=True, timeout=15)

    def records(self):
        return [json.loads(line) for line in (self.base / '.local/ctrl/audit.jsonl').read_text().splitlines()]

    def fake_scp(self, code=0, relay=False):
        script = self.bin / 'scp'
        script.write_text('#!' + sys.executable + '\nimport json,sys\nfrom pathlib import Path\n' +
                          f'with open({str(self.capture)!r},"a") as stream: stream.write(json.dumps(sys.argv[1:])+"\\n")\n' +
                          ('if "@" in sys.argv[-2]: Path(sys.argv[-1]).write_bytes(b"relay content")\n' if relay else '') +
                          f'raise SystemExit({code})\n')
        script.chmod(0o755)

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_local_binary_copy_and_overwrite(self):
        dest = self.base / 'copy.bin'
        self.assert_ok(self.run_ctrl(self.source, dest, '--yes', packaged=True))
        self.assertEqual(dest.read_bytes(), self.source.read_bytes())
        self.source.write_bytes(b'updated')
        self.assert_ok(self.run_ctrl(self.source, dest, '--yes'))
        self.assertEqual(dest.read_bytes(), b'updated')
        self.assertEqual(self.records()[-1]['effects'], 'write')

    def test_local_copy_needs_consent_and_plan_never_copies(self):
        dest = self.base / 'copy.bin'
        self.assertNotEqual(self.run_ctrl(self.source, dest).returncode, 0)
        self.assert_ok(self.run_ctrl(self.source, dest, '--dry-run'))
        self.assertFalse(dest.exists())
        self.assertNotIn('private-test-value', json.dumps(self.records()))

    def test_directory_copy_requires_recursive_and_preserves_tree(self):
        source = self.base / 'source'
        (source / 'nested').mkdir(parents=True)
        (source / 'nested/data').write_bytes(b'contents')
        destination = self.base / 'destination'
        self.assertNotEqual(self.run_ctrl(source, destination, '--yes').returncode, 0)
        self.assertFalse(destination.exists())
        self.assert_ok(self.run_ctrl(source, destination, '--recursive', '--yes'))
        self.assertEqual((destination / 'nested/data').read_bytes(), b'contents')

    def test_directory_cannot_be_copied_into_itself(self):
        source = self.base / 'tree'
        source.mkdir()
        (source / 'data').write_text('keep')
        result = self.run_ctrl(source, source / 'backup', '--recursive', '--yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((source / 'backup').exists())
        self.assertEqual((source / 'data').read_text(), 'keep')

    def test_upload_endpoint_delegates_to_selected_target_and_links_audit(self):
        self.fake_scp()
        self.assert_ok(self.run_ctrl(self.source, 'demo:/tmp/destination file', '--yes'))
        argv = json.loads(self.capture.read_text().splitlines()[0])
        self.assertIn('-s', argv)
        self.assertIn('-P', argv)
        self.assertIn('2200', argv)
        self.assertIn(str(self.base / 'key with spaces'), argv)
        self.assertEqual(argv[-2:], [str(self.source), 'deploy@demo.example.invalid:/tmp/destination file'])
        finished = [r for r in self.records() if r['event'] == 'finished']
        self.assertEqual([r['target'] for r in finished], ['demo', 'local'])
        self.assertEqual(finished[0]['parent_run_id'], finished[1]['run_id'])

    def test_download_supports_endpoint_and_explicit_target_forms(self):
        self.fake_scp()
        destination = self.base / 'download'
        for args in [('demo:/var/log/app.log', destination, '--yes'),
                     ('logs/app.log', destination, '--on', 'demo', '--download', '--yes')]:
            self.assert_ok(self.run_ctrl(*args))
        commands = [json.loads(line) for line in self.capture.read_text().splitlines()]
        self.assertEqual(commands[0][-2:], ['deploy@demo.example.invalid:/var/log/app.log', str(destination)])
        self.assertEqual(commands[1][-2:], ['deploy@demo.example.invalid:/srv/app/logs/app.log', str(destination)])

    def test_remote_to_remote_uses_two_connections_and_cleans_private_relay(self):
        self.fake_scp(relay=True)
        self.assert_ok(self.run_ctrl('demo:/tmp/report.bin', 'other:/tmp/received.bin', '--yes'))
        commands = [json.loads(line) for line in self.capture.read_text().splitlines()]
        self.assertEqual(len(commands), 2)
        self.assertEqual(commands[0][-2], 'deploy@demo.example.invalid:/tmp/report.bin')
        self.assertEqual(commands[1][-1], 'other@other.example.invalid:/tmp/received.bin')
        self.assertIn('2222', commands[1])
        self.assertEqual(commands[0][-1], commands[1][-2])
        self.assertFalse(Path(commands[0][-1]).exists(), 'Private relay was not removed')

    def test_unknown_targets_and_ambiguous_forms_fail_before_transfer(self):
        self.fake_scp()
        for args in [(self.source, 'missing:/tmp/out', '--yes'),
                     ('demo:/tmp/file', 'missing:/tmp/out', '--yes'),
                     (self.source, 'demo:/tmp/out', '--on', 'demo', '--yes'),
                     (self.source, '/tmp/out', '--download', '--yes')]:
            self.assertNotEqual(self.run_ctrl(*args).returncode, 0)
        self.assertFalse(self.capture.exists())

    def test_failed_transfer_status_is_preserved_through_delegation(self):
        self.fake_scp(code=17)
        result = self.run_ctrl(self.source, 'demo:/tmp/out', '--yes')
        self.assertEqual(result.returncode, 17)
        finished = [r for r in self.records() if r['event'] == 'finished']
        self.assertEqual([r['exit_code'] for r in finished], [17, 17])

    def test_remote_globs_are_rejected_before_sftp(self):
        self.fake_scp()
        self.assertNotEqual(self.run_ctrl('demo:/tmp/*.log', self.base/'out', '--yes').returncode, 0)
        self.assertFalse(self.capture.exists())
