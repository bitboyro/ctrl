"""Publishing a package must never dereference private paths or leave mixed artifacts."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ctrl-distribution-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.project = self.base / 'project'
        for name in ('scripts', 'src', 'operations', 'docs', 'completions', 'examples/public-demo', 'dist'):
            (self.project / name).mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / 'scripts/build.py', self.project / 'scripts/build.py')
        shutil.copy(ROOT / 'src/ctrl.py', self.project / 'src/ctrl.py')
        (self.project / 'VERSION').write_text('1.2.3\n')
        for name in ('README.md', 'SKILL.md', 'install.sh'):
            (self.project / name).write_text('public content')
        (self.project / 'examples/README.md').write_text('public example index')
        self.catalog = self.project / 'examples/catalog.json'
        self.catalog.write_text(json.dumps([{'path': 'public-demo'}]))
        (self.project / 'examples/public-demo/README.md').write_text('public example')
        self.private = self.base / 'private'
        self.private.mkdir()
        (self.private / 'secret.md').write_text('PRIVATE-DATA-MUST-NOT-SHIP')
        self.previous = {}
        for name in ('ctrl', 'ctrl.sha256', 'ctrl-1.2.3.tar.gz', 'ctrl-1.2.3.tar.gz.sha256'):
            payload = ('previous ' + name).encode()
            (self.project / 'dist' / name).write_bytes(payload)
            self.previous[name] = payload

    def build(self):
        return subprocess.run([sys.executable, str(self.project / 'scripts/build.py')],
                              capture_output=True, text=True, timeout=10)

    def assert_previous_artifacts_preserved(self):
        for name, payload in self.previous.items():
            self.assertEqual((self.project / 'dist' / name).read_bytes(), payload, name)

    def test_nested_example_file_symlink_cannot_disclose_private_file(self):
        (self.project / 'examples/public-demo/reference.md').symlink_to(self.private / 'secret.md')
        result = self.build()
        self.assertNotEqual(result.returncode, 0, 'Builder followed an unreviewed file symlink')
        self.assert_previous_artifacts_preserved()

    def test_nested_example_directory_symlink_cannot_disclose_private_tree(self):
        (self.project / 'examples/public-demo/assets').symlink_to(self.private, target_is_directory=True)
        self.assertNotEqual(self.build().returncode, 0)
        self.assert_previous_artifacts_preserved()

    def test_embedded_docs_symlink_is_rejected_before_publishing_executable(self):
        (self.project / 'docs/private.md').symlink_to(self.private / 'secret.md')
        self.assertNotEqual(self.build().returncode, 0)
        self.assert_previous_artifacts_preserved()

    def test_missing_example_does_not_partially_replace_existing_release(self):
        self.catalog.write_text(json.dumps([{'path': 'missing-example'}]))
        self.assertNotEqual(self.build().returncode, 0)
        self.assert_previous_artifacts_preserved()

    def test_invalid_or_duplicate_catalog_does_not_replace_existing_release(self):
        for entries in ([{'path': '../private'}], [{'path': 'public-demo'}, {'path': 'public-demo'}]):
            with self.subTest(entries=entries):
                self.catalog.write_text(json.dumps(entries))
                self.assertNotEqual(self.build().returncode, 0)
                self.assert_previous_artifacts_preserved()

    def test_environment_variants_are_excluded_and_resulting_checksums_match(self):
        for name in ('.env', '.env.local', '.env.production', 'secrets.env'):
            (self.project / 'examples/public-demo' / name).write_text('PRIVATE-DATA-MUST-NOT-SHIP')
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        with tarfile.open(self.project / 'dist/ctrl-1.2.3.tar.gz') as archive:
            for member in archive.getmembers():
                if member.isfile():
                    self.assertNotIn(b'PRIVATE-DATA-MUST-NOT-SHIP', archive.extractfile(member).read(), member.name)
        for checksum in (self.project / 'dist').glob('*.sha256'):
            expected, name = checksum.read_text().split()
            self.assertEqual(hashlib.sha256((checksum.parent / name).read_bytes()).hexdigest(), expected)
