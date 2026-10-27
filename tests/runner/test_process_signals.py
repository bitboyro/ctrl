"""Cancellation must distinguish a completed group from a denied live process."""
import importlib.util
from pathlib import Path
import signal
import subprocess
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ctrl_signals', ROOT / 'src/ctrl.py')
ctrl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ctrl)


class ProcessSignalTests(unittest.TestCase):
    def child(self, status=0):
        return mock.Mock(pid=12345, poll=mock.Mock(return_value=status))

    def test_completed_empty_or_zombie_group_is_already_cancelled(self):
        for output in ['', '12346 12345 Z\n', '12346 12345 Z+\n17 17 S\n']:
            with self.subTest(output=output), mock.patch.object(ctrl.os, 'killpg', side_effect=PermissionError()), mock.patch.object(ctrl.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, output, '')):
                ctrl.signal_process_group(self.child(), signal.SIGKILL)

    def test_denied_live_descendant_is_not_treated_as_success(self):
        with mock.patch.object(ctrl.os, 'killpg', side_effect=PermissionError()), mock.patch.object(ctrl.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '12346 12345 S\n', '')):
            with self.assertRaises(PermissionError):
                ctrl.signal_process_group(self.child(), signal.SIGKILL)

    def test_running_child_and_failed_process_snapshot_fail_closed(self):
        for status, code, output in [(None,0,''), (0,1,''), (0,0,'invalid row')]:
            with self.subTest(status=status,code=code), mock.patch.object(ctrl.os, 'killpg', side_effect=PermissionError()), mock.patch.object(ctrl.subprocess, 'run', return_value=subprocess.CompletedProcess([], code, output, '')):
                with self.assertRaises(PermissionError):
                    ctrl.signal_process_group(self.child(status), signal.SIGKILL)
