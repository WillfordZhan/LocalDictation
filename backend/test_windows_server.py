"""Launcher lifetime tracking never rechecks or terminates a numeric PID."""
import ctypes
import threading
import unittest
from unittest.mock import Mock, patch

from windows_server import ParentProcessWatch, open_parent_handle


class ParentWatchTests(unittest.TestCase):
    def test_waits_for_pinned_process_then_calls_shutdown_once(self):
        kernel = Mock()
        kernel.WaitForSingleObject.side_effect = [0x102, 0x102, 0]
        handle = object()
        open_handle = Mock(return_value=(kernel, handle))
        called = threading.Event()
        watcher = ParentProcessWatch(123, open_handle=open_handle)
        watcher.start(called.set)
        self.assertTrue(called.wait(2))
        watcher.close()
        open_handle.assert_called_once_with(123)
        self.assertEqual(kernel.WaitForSingleObject.call_count, 3)
        self.assertTrue(all(call.args == (handle, 250) for call in kernel.WaitForSingleObject.call_args_list))
        kernel.CloseHandle.assert_called_once_with(handle)
        kernel.TerminateProcess.assert_not_called()

    def test_normal_service_stop_does_not_report_launcher_exit_and_closes_once(self):
        kernel = Mock()
        entered, release = threading.Event(), threading.Event()
        def wait(handle, timeout):
            entered.set()
            release.wait(1)
            return 0x102
        kernel.WaitForSingleObject.side_effect = wait
        callback = Mock()
        watcher = ParentProcessWatch(123, open_handle=lambda pid: (kernel, 99))
        watcher.start(callback)
        self.assertTrue(entered.wait(1))
        watcher.stop.set(); release.set()
        watcher.close(); watcher.close()
        callback.assert_not_called()
        kernel.CloseHandle.assert_called_once_with(99)

    def test_unavailable_parent_fails_before_starting_thread(self):
        open_handle = Mock(side_effect=OSError("parent gone"))
        with self.assertRaises(OSError):
            ParentProcessWatch(123, open_handle=open_handle)

    def test_parent_identity_and_creation_time_reject_recycled_pid(self):
        kernel = Mock()
        kernel.OpenProcess.return_value = 77
        kernel.GetCurrentProcess.return_value = 88
        kernel.WaitForSingleObject.return_value = 0x102
        created = {77: 100, 88: 200}
        def get_times(handle, creation, *remaining):
            creation._obj.dwHighDateTime = 0
            creation._obj.dwLowDateTime = created[handle]
            return True
        kernel.GetProcessTimes.side_effect = get_times
        with patch("windows_server.os.name", "nt"), patch("windows_server.os.getpid", return_value=456), \
                patch("windows_server.os.getppid", return_value=123), \
                patch("ctypes.WinDLL", return_value=kernel, create=True):
            with self.assertRaises(ValueError):
                open_parent_handle(124)
            kernel.OpenProcess.assert_not_called()
            self.assertEqual(open_parent_handle(123), (kernel, 77))
            kernel.OpenProcess.assert_called_once_with(0x00101000, False, 123)
            created[77] = 300  # New process reused launcher's PID after this child started.
            with self.assertRaises(ValueError):
                open_parent_handle(123)
            kernel.CloseHandle.assert_called_once_with(77)
            created[77] = 100
            kernel.WaitForSingleObject.return_value = 0
            with self.assertRaises(OSError):
                open_parent_handle(123)
        kernel.TerminateProcess.assert_not_called()


if __name__ == "__main__":
    unittest.main()
