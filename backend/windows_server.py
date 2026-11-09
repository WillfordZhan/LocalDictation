#!/usr/bin/env python3
"""Loopback Windows service using the shared dictation and Prompt protocols."""
from __future__ import annotations

import argparse
from http.server import ThreadingHTTPServer
import logging
import os
from pathlib import Path
import signal
import threading

from server import DictationService, make_handler
from windows_models import WindowsModels
from windows_setup import default_data_dir


def open_parent_handle(pid):
    """Pin the actual launcher process, rejecting a recycled PID before startup.

    A handle keeps referring to the original process after it exits. Comparing
    creation times also rejects the narrow race where its PID was reused before
    we obtained that handle. No process is terminated through this handle.
    """
    if os.name != "nt":
        raise ValueError("--parent-pid 只支持 Windows 进程句柄。")
    if pid <= 0 or pid == os.getpid() or pid != os.getppid():
        raise ValueError("父进程标识与启动器不一致。")
    import ctypes
    from ctypes import wintypes
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.WaitForSingleObject.restype = wintypes.DWORD
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.OpenProcess(0x00100000 | 0x1000, False, pid)  # SYNCHRONIZE | QUERY_LIMITED_INFORMATION
    if not handle:
        raise OSError("启动器已退出或无法访问，服务未启动。")

    def created(process):
        times = [wintypes.FILETIME() for _ in range(4)]
        if not kernel.GetProcessTimes(process, *(ctypes.byref(value) for value in times)):
            raise OSError("无法验证启动器进程身份。")
        return (times[0].dwHighDateTime << 32) | times[0].dwLowDateTime

    try:
        if created(handle) > created(kernel.GetCurrentProcess()):
            raise ValueError("启动器进程标识已被重用，服务未启动。")
        if kernel.WaitForSingleObject(handle, 0) != 0x102:  # WAIT_TIMEOUT means alive.
            raise OSError("启动器已退出，服务未启动。")
        return kernel, handle
    except Exception:
        kernel.CloseHandle(handle)
        raise


class ParentProcessWatch:
    def __init__(self, pid, *, open_handle=open_parent_handle):
        self.kernel, self.handle = open_handle(pid)
        self.stop = threading.Event()
        self.thread = None

    def start(self, on_exit):
        def watch():
            while not self.stop.is_set():
                outcome = self.kernel.WaitForSingleObject(self.handle, 250)
                if outcome == 0x102:  # WAIT_TIMEOUT
                    continue
                # A signalled or invalid launcher handle cannot own a service.
                # Only shut down this service and its owned model child.
                if not self.stop.is_set():
                    on_exit()
                return
        self.thread = threading.Thread(target=watch, name="launcher-lifetime", daemon=True)
        self.thread.start()

    def close(self):
        self.stop.set()
        if self.thread is not None and self.thread is not threading.current_thread():
            self.thread.join(timeout=2)
        if self.handle is not None:
            self.kernel.CloseHandle(self.handle)
            self.handle = None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=default_data_dir())
    parser.add_argument("--port", type=int, default=8767)
    parser.add_argument("--llama-server", type=Path, required=True)
    parser.add_argument("--threads", type=int, default=None)
    parser.add_argument("--parent-pid", type=int, help="绑定桌面启动器，启动器退出后自动停止服务")
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65535 or (args.threads is not None and not 1 <= args.threads <= 64):
        parser.error("端口或线程数无效。")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    parent = ParentProcessWatch(args.parent_pid) if args.parent_pid is not None else None
    models = WindowsModels(args.data_dir, args.llama_server, threads=args.threads)
    service = DictationService(models, prompt_directory=args.data_dir)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(service))
    server.daemon_threads = True

    def shutdown(signum, frame):
        # shutdown must run outside serve_forever's thread to avoid deadlock.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)
    if parent:
        def launcher_exited():
            models.close()
            server.shutdown()
        parent.start(launcher_exited)
    service.start()
    logging.getLogger("local-dictation").info("Windows service listening on 127.0.0.1:%d", args.port)
    try:
        server.serve_forever()
    finally:
        if parent:
            parent.close()
        service.streams.close()
        models.close()
        server.server_close()
        service.worker.shutdown(wait=True)


if __name__ == "__main__":
    main()
