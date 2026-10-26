"""Prove real-integration tests cannot be redirected to a remote Docker context."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


class IntegrationBoundaryTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('ctrl_real_boundaries', ROOT / 'tests/integration/test_real_services.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def test_remote_context_overrides_local_host_and_is_refused_before_daemon_access(self):
        env = dict(DOCKER_CONTEXT='remote-context', DOCKER_HOST='unix:///local.sock')
        with patch.object(self.module, 'checked', return_value='ssh://remote.example.invalid') as command:
            with self.assertRaises(RuntimeError):
                self.module.local_docker_endpoint(env)
        self.assertEqual(command.call_count, 1)
        self.assertEqual(command.call_args[0][:4], ('docker', 'context', 'inspect', 'remote-context'))

    def test_local_context_precedence_is_resolved_and_frozen(self):
        env = dict(DOCKER_CONTEXT='local-context', DOCKER_HOST='ssh://unused.example.invalid')
        with patch.object(self.module, 'checked', return_value='unix:///local.sock'):
            self.assertEqual(self.module.local_docker_endpoint(env), 'unix:///local.sock')

    def test_remote_host_is_rejected_without_invoking_docker(self):
        with patch.object(self.module, 'checked') as command, self.assertRaises(RuntimeError):
            self.module.local_docker_endpoint(dict(DOCKER_HOST='tcp://remote.example.invalid:2376'))
        command.assert_not_called()

    def test_operation_adapter_pins_endpoint_after_runner_filters_parent_environment(self):
        with tempfile.TemporaryDirectory(prefix='ctrl-docker-boundary-') as directory:
            root = Path(directory)
            binary = root / 'actual-docker'
            binary.write_text('#!' + sys.executable + '\nimport os,json,sys\nprint(json.dumps(dict(argv=sys.argv[1:],context=os.environ.get("DOCKER_CONTEXT"),host=os.environ.get("DOCKER_HOST"))))\n')
            binary.chmod(0o755)
            adapter = self.module.docker_adapter(root, str(binary), 'unix:///test-local.sock')
            result = subprocess.run([str(adapter), 'compose', 'up'], capture_output=True, text=True,
                                    env=dict(os.environ, DOCKER_CONTEXT='remote-context', DOCKER_HOST='ssh://remote.example.invalid'))
            self.assertEqual(result.returncode, 0, result.stderr)
            received = json.loads(result.stdout)
            self.assertEqual(received, dict(argv=['--host', 'unix:///test-local.sock', 'compose', 'up'],
                                            context=None, host='unix:///test-local.sock'))
