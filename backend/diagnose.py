#!/usr/bin/env python3
"""Read-only diagnostics; no model imports, recording access, or ObjC calls."""
from __future__ import annotations

import argparse
from datetime import datetime
import json
import os
import platform
from pathlib import Path
import re
import subprocess
import time
import urllib.error
import urllib.request

from model_artifacts import CLEANUP_MODEL_IDS, inspect_model, load_manifest, selected_models


PACKAGE = Path(__file__).resolve().parent.parent
RUNTIME = Path.home() / "Library/Application Support/LocalDictation/Runtime"
HEALTH_URL = "http://127.0.0.1:8765/health"
ATTRIBUTION_NOTE = (
    "当前存活进程与历史崩溃报告分开列出。PID 可能被复用；必须同时核对启动时间和程序入口，"
    "不能仅凭报告名称 Python 就认定本地模型服务崩溃。"
)


def python_metadata(python_bin):
    """Use isolated stdlib metadata only; no site initialization or GPU import."""
    script = """
import importlib.metadata, json, pathlib, platform, sys, sysconfig
version = f'{sys.version_info.major}.{sys.version_info.minor}'
candidate = pathlib.Path(sys.argv[1]).parent.parent / 'lib' / ('python' + version) / 'site-packages'
site = candidate if candidate.is_dir() else pathlib.Path(sysconfig.get_path('purelib'))
packages = {item.metadata['Name'].lower().replace('_', '-'): item.version
            for item in importlib.metadata.distributions(path=[str(site)]) if item.metadata['Name']}
print(json.dumps({'version': platform.python_version(), 'machine': platform.machine(),
                  'site_packages': str(site), 'packages': packages}))
"""
    result = subprocess.run([str(python_bin), "-I", "-S", "-B", "-c", script, str(python_bin)],
                            capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise ValueError("Python 解释器未能运行只读检查。")
    return json.loads(result.stdout)


def installation_report(runtime_dir=RUNTIME, python_bin=None, asr_backend=None, *, deep=False,
                        backend_dir=None, manifest=None, cleanup_model=None):
    runtime_dir = Path(runtime_dir)
    backend_dir = Path(backend_dir) if backend_dir else Path(__file__).resolve().parent
    python_bin = Path(python_bin) if python_bin else runtime_dir / "local-dictation-venv/bin/python"
    checks = []
    def check(identifier, status, message, path=None):
        checks.append({"id": identifier, "status": status, "message": message,
                       **({"path": str(path)} if path is not None else {})})
    machine = platform.machine()
    try:
        supported_os = platform.system() == "Darwin" and int(platform.mac_ver()[0].split(".")[0]) >= 14
    except ValueError:
        supported_os = False
    supported = supported_os and machine == "arm64"
    check("platform", "ok" if supported else "invalid",
          "Apple Silicon 与 macOS 版本满足要求。" if supported else "需要 Apple Silicon 与 macOS 14 或更新系统。")
    if asr_backend is None:
        selection = runtime_dir / "asr-backend"
        try:
            asr_backend = selection.read_text().strip() if selection.exists() else "qwen"
        except OSError:
            asr_backend = "unreadable"
    valid_selection = asr_backend in ("qwen", "whisper")
    check("asr_selection", "ok" if valid_selection else "invalid",
          "识别模型选择有效。" if valid_selection else "识别模型配置不可读取或不受支持。")
    if cleanup_model is None:
        selection = runtime_dir / "cleanup-model"
        try:
            if selection.is_symlink() or (selection.exists() and not selection.is_file()):
                cleanup_model = "unreadable"
            else:
                cleanup_model = selection.read_text().strip() if selection.exists() else "cleanup"
        except OSError:
            cleanup_model = "unreadable"
    valid_cleanup = cleanup_model in CLEANUP_MODEL_IDS
    check("cleanup_selection", "ok" if valid_cleanup else "invalid",
          "整理模型选择有效。" if valid_cleanup else "整理模型配置不可读取或不受支持。")
    if not python_bin.is_file() or not os.access(python_bin, os.X_OK):
        check("python", "missing", "Python 运行环境未就绪。", python_bin)
    else:
        try:
            metadata = python_metadata(python_bin)
            compatible = metadata["machine"] == "arm64" and metadata["version"].split(".")[:2] == ["3", "11"]
            check("python", "ok" if compatible else "invalid",
                  f"Python {metadata['version']} / {metadata['machine']}。", python_bin)
        except (OSError, ValueError, TypeError, KeyError, subprocess.TimeoutExpired):
            metadata = None
            check("python", "invalid", "运行环境检查未完成，请重新安装或检查文件权限。", python_bin)
        try:
            pins = {}
            for line in (backend_dir / "requirements.txt").read_text().splitlines():
                match = re.fullmatch(r"([A-Za-z0-9_.-]+)==([^\s]+)", line.strip())
                if match: pins[match[1].lower().replace("_", "-")] = match[2]
            packages = metadata["packages"] if metadata else {}
            mismatches = [name for name, version in pins.items() if packages.get(name) != version]
            check("dependencies", "invalid" if mismatches or not pins else "ok",
                  "依赖版本需要修复：" + "、".join(mismatches) if mismatches else
                  "依赖版本清单为空。" if not pins else "依赖版本与发行清单一致（未加载模型）。")
        except (OSError, ValueError, TypeError, KeyError):
            check("dependencies", "invalid", "依赖版本清单无法读取或格式无效。")
    resources = ("server.py", "streaming.py", "prompt_store.py", "prompt-imports.json", "start.sh", "download_models.py",
                 "model_artifacts.py", "model-manifest.json", "requirements.txt", "diagnose.py")
    missing_resources = [name for name in resources if not (backend_dir / name).is_file()]
    check("backend_resources", "invalid" if missing_resources else "ok",
          "后端资源缺失：" + "、".join(missing_resources) if missing_resources else "后端资源完整。", backend_dir)
    models = []
    try:
        catalog = load_manifest(backend_dir / "model-manifest.json") if manifest is None else manifest
        if valid_selection and valid_cleanup:
            for model in selected_models(asr_backend, catalog, cleanup_model):
                status = inspect_model(runtime_dir / "models" / model["directory"], model, deep=deep)
                models.append(status)
                title = "文字整理" if model["kind"] == "cleanup" else "语音识别"
                check("model_" + model["id"], status["status"], title + " · " + status["message"], status["path"])
    except (OSError, ValueError, KeyError, TypeError):
        check("model_manifest", "invalid", "模型校验清单不可读取或内容无效。")
    ready = bool(models) and all(row["status"] == "ok" for row in checks)
    model_check_ids = {"model_" + row["id"] for row in models}
    blocked = any(row["status"] != "ok" for row in checks if row["id"] not in model_check_ids)
    health = check_health()
    busy = bool(health.get("identity_matches") and health.get("busy"))
    return {"schema": 1, "ready": ready, "blocked": blocked,
            "can_download": bool(not blocked and models and not ready and not busy),
            "download_block_reason": "语音服务正在处理录音，请完成后再配置模型。" if busy else None,
            "service_busy": busy, "checks": checks, "models": models,
            "asr_backend": asr_backend, "cleanup_model": cleanup_model,
            "runtime_dir": str(runtime_dir), "python_bin": str(python_bin),
            "required_download_bytes": sum(row["required_download_bytes"] for row in models) if models else None,
            "verification": "sha256" if deep else "receipt_and_stat", "health": health}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def check_health():
    result = {"url": HEALTH_URL, "reachable": False, "identity_matches": False}
    # Bypass proxy settings and redirects: this diagnostic only contacts the
    # known loopback health endpoint and never requests transcription.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(HEALTH_URL, timeout=3) as response:
            result["http_status"] = response.status
            result["reachable"] = True
            data = json.loads(response.read(65536))
        if not isinstance(data, dict):
            raise ValueError("健康检查返回的不是 JSON 对象")
        for key in ("service", "version", "status", "ready", "busy", "asr_ready", "cleanup_ready",
                    "supports_options", "supports_prompt_versions", "active_prompt_version_id", "models"):
            if key in data:
                result[key] = data[key]
        result["identity_matches"] = data.get("service") == "local-dictation"
        if not result["identity_matches"]:
            result["error"] = "端口上的服务身份不匹配，不能作为本地口述服务状态。"
    except urllib.error.HTTPError as exc:
        result.update(reachable=True, http_status=exc.code, error="健康检查返回 HTTP 错误或重定向。")
    except (OSError, ValueError, urllib.error.URLError) as exc:
        result["error"] = str(exc)
    return result


def current_processes(warnings):
    app_path = str(PACKAGE / "LocalDictation.app/Contents/MacOS/LocalDictation")
    server_paths = {str(PACKAGE / "backend/server.py"), str(RUNTIME / "backend/server.py")}
    candidates = set()
    env = dict(os.environ, LC_ALL="C")
    # pgrep returns only IDs. Read ps arguments only for candidates matching
    # this delivery directory or the installed Runtime, then keep validated
    # App/backend entries. Never inspect unrelated process command lines.
    for path in (app_path, *sorted(server_paths)):
        try:
            found = subprocess.run(
                ["pgrep", "-f", "(^| )" + re.escape(path) + "( |$)"],
                text=True, capture_output=True, timeout=3, env=env,
            )
            if found.returncode not in (0, 1):
                warnings.append("无法查询交付目录或 Runtime 的进程候选。")
                continue
            candidates.update(int(pid) for pid in found.stdout.split() if pid.isdigit())
        except (OSError, subprocess.TimeoutExpired):
            warnings.append("进程候选查询失败或超时。")
    if not candidates:
        return []
    try:
        query = subprocess.run(
            ["ps", "-p", ",".join(map(str, sorted(candidates))),
             "-o", "pid=,ppid=,lstart=,command="],
            text=True, capture_output=True, timeout=3, env=env,
        )
    except (OSError, subprocess.TimeoutExpired):
        warnings.append("无法读取候选进程的标识与启动时间。")
        return []
    rows = []
    row_pattern = re.compile(
        r"^\s*(\d+)\s+(\d+)\s+"
        r"([A-Za-z]{3}\s+[A-Za-z]{3}\s+\d+\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+(.+)$"
    )
    backend_patterns = [re.compile(
        r"^.+/(?:Python|python(?:3(?:\.\d+)?)?)\s+" + re.escape(path) + r"(?:\s|$)"
    ) for path in server_paths]
    for line in query.stdout.splitlines():
        match = row_pattern.match(line)
        if not match:
            continue
        pid, ppid, started, command = match.groups()
        if command == app_path or command.startswith(app_path + " "):
            kind = "app"
        elif any(pattern.match(command) for pattern in backend_patterns):
            kind = "backend"
        else:
            continue
        rows.append({"kind": kind, "pid": int(pid), "ppid": int(ppid), "started_at": started})
    return sorted(rows, key=lambda row: (row["kind"], row["pid"]))


def read_report(path, root):
    decoder = json.JSONDecoder()
    raw = path.read_text(encoding="utf-8")
    first, end = decoder.raw_decode(raw.lstrip())
    remainder = raw.lstrip()[end:].lstrip()
    # Apple IPS commonly has one metadata JSON line followed by the report.
    data = decoder.raw_decode(remainder)[0] if remainder else first
    if not isinstance(data, dict):
        raise ValueError("IPS 内容不是 JSON 对象")
    result = {"report": str(path.relative_to(root))}
    for key in ("procName", "pid", "procLaunch", "captureTime"):
        result[key] = data.get(key)
    exception = data.get("exception") or {}
    termination = data.get("termination") or {}
    result["exception"] = {k: exception[k] for k in ("type", "signal", "codes") if k in exception}
    result["termination"] = {
        k: termination[k] for k in ("namespace", "code", "indicator", "byProc", "byPid") if k in termination
    }
    threads = data.get("threads") or []
    index = data.get("faultingThread")
    fault = threads[index] if isinstance(index, int) and 0 <= index < len(threads) else {}
    result["symbolized_stack"] = [
        frame["symbol"] for frame in fault.get("frames", [])
        if isinstance(frame, dict) and isinstance(frame.get("symbol"), str)
    ][:10]
    return result


def recent_reports(hours, warnings):
    root = Path.home() / "Library/Logs/DiagnosticReports"
    cutoff = time.time() - hours * 3600
    candidates = []
    # Deliberately inspect only these two direct directories, not a recursive
    # search of diagnostics or other applications' logs and user data.
    for directory in (root, root / "Retired"):
        if not directory.exists():
            continue
        try:
            for path in directory.iterdir():
                if path.suffix != ".ips" or not path.name.startswith(("Python-", "LocalDictation-")):
                    continue
                if path.is_symlink() or not path.is_file():
                    continue
                modified = path.stat().st_mtime
                if modified >= cutoff:
                    candidates.append((modified, path))
        except OSError:
            warnings.append(f"无法读取诊断目录 {directory.name}。")
    reports = []
    for _, path in sorted(candidates, key=lambda entry: (entry[0], entry[1].name), reverse=True)[:5]:
        try:
            reports.append(read_report(path, root))
        except (OSError, ValueError, TypeError) as exc:
            reports.append({"report": str(path.relative_to(root)), "error": f"无法解析 IPS：{type(exc).__name__}"})
    return reports


def print_human(report):
    print("本地口述只读诊断 · " + report["checked_at"])
    health = report["health"]
    if health["identity_matches"]:
        print(f"本地服务：身份正确；ready={health.get('ready')}，busy={health.get('busy')}，状态={health.get('status')}")
    else:
        print("本地服务：" + health.get("error", "未找到可确认身份的服务。"))
    if not report["processes"]:
        print("当前进程：未找到交付目录的 App 或交付目录 / Runtime 的后端。")
    for process in report["processes"]:
        name = "App" if process["kind"] == "app" else "后端"
        print(f"{name}：PID {process['pid']}，PPID {process['ppid']}，启动于 {process['started_at']}")
    print(f"最近 {report['report_window_hours']:g} 小时的 Python/LocalDictation 报告：{len(report['recent_crashes'])} 份（最多 5 份）。")
    for crash in report["recent_crashes"]:
        print("\n报告：" + crash["report"])
        if "error" in crash:
            print(crash["error"])
            continue
        print(f"  程序 {crash['procName']}，PID {crash['pid']}；启动 {crash['procLaunch']}；捕获 {crash['captureTime']}")
        print("  异常：" + json.dumps(crash["exception"], ensure_ascii=False))
        print("  终止：" + json.dumps(crash["termination"], ensure_ascii=False))
        print("  已符号化崩溃栈（前 10 帧）：")
        for symbol in crash["symbolized_stack"]:
            print("    " + symbol)
    print("\n" + ATTRIBUTION_NOTE)
    for warning in report["warnings"]:
        print("读取限制：" + warning)
    print("未读取录音或转写内容，未调用模型，未修改或保存诊断文件。")


def main(argv=None):
    parser = argparse.ArgumentParser(description="只读检查本地口述进程、健康状态及最近崩溃报告。")
    parser.add_argument("--json", action="store_true", help="输出 JSON，便于复制诊断结果")
    parser.add_argument("--hours", type=float, default=24, help="崩溃报告的最近时间窗口，默认 24 小时")
    parser.add_argument("--installation", action="store_true", help="只读检查安装环境与模型，不读取崩溃报告")
    parser.add_argument("--runtime-dir", type=Path, default=RUNTIME)
    parser.add_argument("--python-bin", type=Path, help="待检查的内置 Python；默认兼容旧 Runtime venv")
    parser.add_argument("--asr-backend", choices=("qwen", "whisper"))
    parser.add_argument("--cleanup-model", choices=CLEANUP_MODEL_IDS,
                        help="检查指定整理模型；默认使用 Runtime 中的选择，未配置时使用 cleanup")
    parser.add_argument("--deep", action="store_true", help="对模型重算完整 SHA-256，不加载模型")
    args = parser.parse_args(argv)
    if args.installation:
        report = installation_report(args.runtime_dir, args.python_bin, args.asr_backend,
                                     deep=args.deep, cleanup_model=args.cleanup_model)
        if args.json:
            print(json.dumps(report, ensure_ascii=False, indent=2))
        else:
            for item in report["checks"]: print(f"[{item['status']}] {item['message']}")
        return
    if not 0 < args.hours < float("inf"):
        parser.error("--hours 必须是有限正数")
    warnings = []
    report = {
        "checked_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "health": check_health(),
        "processes": current_processes(warnings),
        "report_window_hours": args.hours,
        "recent_crashes": recent_reports(args.hours, warnings),
        "attribution_note": ATTRIBUTION_NOTE,
        "warnings": warnings,
    }
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print_human(report)


if __name__ == "__main__":
    main()
