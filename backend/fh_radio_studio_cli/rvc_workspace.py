"""RVC inference adapter sharing the existing audio result and draft workflow."""

from __future__ import annotations

import contextlib
import importlib.resources
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import uuid
import zipfile
from pathlib import Path

from .common import CliError
from .file_lock import exclusive_file_lock
from .rvc_downloads import rvc_download_settings, rvc_mirrored_runtime
from .speech_generation import Engine, GenerationWorkspace, _read, _uv
from .stingers import _copy_snapshot, _write, digest, local_file
from .voice_conversion import RvcCatalog

REVISION = "471dad4e2c8b428a05deba15730f152f7467c27c"
ARCHIVE_SHA = "5bed2c3aec41ad6f903940ea9a07e1328a1ee4837909b764092fd4de5a664677"
ASSETS = {
    "assets/hubert/hubert_base.pt": (
        "hubert_base.pt",
        "f54b40fd2802423a5643779c4861af1e9ee9c1564dc9d32f54f20b5ffba7db96",
    ),
    "assets/rmvpe/rmvpe.pt": (
        "rmvpe.pt",
        "6d62215f4306e3ca278246188607209f09af3dc77ed4232efdd069798c4ec193",
    ),
}


class RvcEngine(Engine):
    def __init__(self, home):
        # Reuse download/retry/TLS/progress and owned process cancellation.
        super().__init__(Path(home))
        self.source = self.home / "source"
        self.environment = self.home / "runtime/.venv"
        self.catalog = RvcCatalog(self.home)
        self.api = self
        self._events = []
        self.state, self.detail = "stopped", "引擎已停止"
        self._request_lock = threading.Lock()
        self._log_handle = None

    def settings(self):
        return self.catalog.read()

    def _set(self, state, detail):
        self.state, self.detail = state, detail

    def components(self):
        checks = {
            "推理源码": [self.source / "infer/modules/vc/modules.py"],
            "推理环境": [
                self.environment / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
            ],
            "特征与音高模型": [self.source / p for p in ASSETS],
        }
        result = [{"name": k, "ready": all(p.is_file() for p in v)} for k, v in checks.items()]
        if self.settings().get("runtime", {}).get("device") == "cuda:0":
            marker = _read(self.home / "installation.json", {})
            packages = self.environment / (
                "Lib/site-packages" if os.name == "nt" else "lib/python3.10/site-packages"
            )
            cuda_ready = marker.get("device") == "cuda:0" or any(
                packages.glob("torch-*+cu*.dist-info")
            )
            result[1]["ready"] = result[1]["ready"] and cuda_ready
        return result

    def status(self):
        checks = self.components()
        installed = all(c["ready"] for c in checks) and (self.home / "installation.json").is_file()
        data = self.settings()
        return {
            "installed": installed,
            "components": checks,
            "home": str(self.home),
            "files": data["files"],
            "parameters": data["parameters"],
            "selection": data.get("selection", {}),
            "downloads": rvc_download_settings(data.get("downloads")),
            "api": {
                "state": self.state if installed else "unconfigured",
                "detail": self.detail,
                "ready": installed and self.state == "ready",
            },
            "runtime": data.get("runtime", {"device": "cpu"}),
            **self.catalog.preset_state(data),
            "connection": {"mode": "rvc", "auto_start": True},
        }

    def stop(self):
        self.interrupted.set()
        response = self._download_response
        if response is not None:
            with contextlib.suppress(Exception):
                response.close()
        process, self.process = self.process, None
        if process is not None:
            if process.poll() is None:
                if os.name == "nt":
                    subprocess.run(
                        ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                        capture_output=True,
                        creationflags=subprocess.CREATE_NO_WINDOW,
                    )
                else:
                    process.terminate()
                with contextlib.suppress(subprocess.TimeoutExpired):
                    process.wait(timeout=5)
                if process.poll() is None:
                    process.kill()
        if self._log_handle:
            self._log_handle.close()
            self._log_handle = None
        self._set("stopped", "引擎已停止")

    def install(self, progress):
        self.stop()
        self.interrupted.clear()
        self.home.mkdir(parents=True, exist_ok=True)
        self._download_progress = progress
        try:
            archive = self.home / "source.zip"
            progress("准备固定版本推理源码")
            if not archive.exists():
                part = archive.with_suffix(".zip.part")
                self.download(
                    f"https://codeload.github.com/Turing-Mirror/RVC-Fabric/zip/{REVISION}", part
                )
                part.replace(archive)
            if digest(archive) != ARCHIVE_SHA:
                raise CliError("RVC源码校验失败，请移除损坏的source.zip后重试。")
            # Include inference/config/license only, never training/UI resources.
            with zipfile.ZipFile(archive) as z:
                for member in z.infolist():
                    relative = Path(*Path(member.filename).parts[1:])
                    if not relative.parts or relative.parts[0] not in (
                        "infer",
                        "configs",
                        "LICENSE",
                    ):
                        continue
                    if "train" in relative.parts or member.is_dir():
                        continue
                    target = self.source / relative
                    if not target.resolve().is_relative_to(self.source.resolve()):
                        raise CliError("RVC压缩包路径无效。")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(z.read(member))
            runtime = self.home / "runtime"
            runtime.mkdir(exist_ok=True)
            resources = importlib.resources.files("backend.fh_radio_studio_cli.rvc_environment")
            original_project = resources.joinpath("pyproject.toml").read_text(encoding="utf-8")
            original_lock = resources.joinpath("uv.lock").read_text(encoding="utf-8")
            progress("安装独立RVC推理依赖（首次下载约数GB；不包含训练组件）")
            env = dict(os.environ, UV_NATIVE_TLS="true", UV_NO_PROGRESS="0")
            for key in (
                "UV_OFFLINE",
                "UV_PROJECT_ENVIRONMENT",
                "VIRTUAL_ENV",
                "UV_NO_INDEX",
                "UV_PYTHON_DOWNLOADS",
                "UV_NO_PYTHON_DOWNLOADS",
                "UV_DEFAULT_INDEX",
                "UV_INDEX_URL",
                "UV_EXTRA_INDEX_URL",
                "UV_INDEX",
            ):
                env.pop(key, None)
            with (self.home / "engine.log").open("a", encoding="utf-8") as log:
                sources = rvc_download_settings(self.settings().get("downloads"))
                attempts = [sources]
                if sources["profile"] != "official":
                    attempts.append(rvc_download_settings())
                for index, selected in enumerate(attempts):
                    if self.interrupted.is_set():
                        raise CliError("安装已暂停，已下载内容保留。")
                    if index:
                        progress("镜像依赖安装未完成，回退官方源继续；已有缓存保留。")
                    project_text, lock_text = rvc_mirrored_runtime(
                        original_project, original_lock, selected
                    )
                    (runtime / "pyproject.toml").write_text(project_text, encoding="utf-8")
                    (runtime / "uv.lock").write_text(lock_text, encoding="utf-8")
                    env["UV_DEFAULT_INDEX"] = selected["pypi"]
                    self.process = subprocess.Popen(
                        [
                            _uv(),
                            "sync",
                            "--frozen",
                            "--verbose",
                            "--color",
                            "never",
                            "--project",
                            str(runtime),
                            "--python",
                            "3.10",
                            "--no-install-project",
                            "--extra",
                            (
                                "torch-cu128"
                                if self.settings().get("runtime", {}).get("device") == "cuda:0"
                                else "torch-cpu"
                            ),
                        ],
                        env=env,
                        stdout=log,
                        stderr=log,
                        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                    )
                    code = self.process.wait()
                    self.process = None
                    if not code or self.interrupted.is_set():
                        break
            if code or self.interrupted.is_set():
                raise CliError("RVC依赖安装未完成，请查看控制台后继续安装。")
            for relative, (name, checksum) in ASSETS.items():
                target = self.source / relative
                if target.exists() and digest(target) == checksum:
                    continue
                progress(f"准备基础模型：{name}")
                part = target.with_suffix(".part")
                self.download(
                    f"https://huggingface.co/lj1995/VoiceConversionWebUI/resolve/main/{name}", part
                )
                if digest(part) != checksum:
                    raise CliError(f"基础模型校验失败：{name}")
                part.replace(target)
            _write(
                self.home / "installation.json",
                {
                    "revision": REVISION,
                    "device": self.settings().get("runtime", {}).get("device", "cpu"),
                },
            )
            self._set("stopped", "组件已就绪，选择音色后可转换。")
            progress("安装完成")
        finally:
            self._download_progress = None

    def request(self, request, progress=None):
        if not self.status()["installed"]:
            raise CliError("请先安装RVC推理引擎。")
        with self._request_lock:
            self.interrupted.clear()
            if self.process is None or self.process.poll() is not None:
                worker = Path(__file__).with_name("rvc_runtime.py")
                env = dict(os.environ, PYTHONIOENCODING="utf-8", UV_NATIVE_TLS="true")
                env.pop("UV_PROJECT_ENVIRONMENT", None)
                self._log_handle = (self.home / "engine.log").open("a", encoding="utf-8")
                self.process = subprocess.Popen(
                    [
                        _uv(),
                        "run",
                        "--offline",
                        "--no-sync",
                        "--project",
                        str(self.home / "runtime"),
                        "python",
                        str(worker),
                        "serve",
                    ],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=self._log_handle,
                    text=True,
                    encoding="utf-8",
                    env=env,
                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                )
            process = self.process
            process.stdin.write(
                json.dumps({**request, "source_root": str(self.source)}, ensure_ascii=False) + "\n"
            )
            process.stdin.flush()
            for line in process.stdout:
                if line.startswith("FH_RVC_PROGRESS "):
                    if progress:
                        progress(json.loads(line[len("FH_RVC_PROGRESS ") :]))
                elif line.startswith("FH_RVC_RESULT "):
                    result = json.loads(line[len("FH_RVC_RESULT ") :])
                    if "error" in result:
                        self._set("error", result["error"])
                        raise CliError(result["error"])
                    metadata = result["result"].get("model_metadata", result["result"])
                    if "version" in metadata:
                        with exclusive_file_lock(self.home / "catalog.lock"):
                            settings = self.catalog.read()
                            for record in settings["files"]:
                                if record["id"] == request["snapshot"]["model"]["id"]:
                                    record.update(validation="valid", metadata=metadata)
                            _write(self.catalog.path, settings)
                    self._set("ready", "RVC引擎可用")
                    return result["result"]
                else:
                    with (self.home / "engine.log").open("a", encoding="utf-8") as log:
                        log.write(line)
            raise CliError("RVC引擎已停止，转换结果未采用。")

    def uninstall(self):
        self.stop()
        for name in ("source", "runtime", "installation.json", "source.zip"):
            path = self.home / name
            if path.is_symlink() or not path.resolve().is_relative_to(self.home):
                raise CliError("引擎路径无效，未删除。")
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink(missing_ok=True)


class RvcWorkspace(GenerationWorkspace):
    def __init__(self, project, engine):
        super().__init__(project, engine, namespace="conversion")

    def status(self):
        with self.lock:
            return {
                "engine": self.engine.status(),
                "jobs": json.loads(json.dumps(self.jobs)),
                "paused": self.paused,
                "inputs": _read(self.folder / "inputs.json", []),
            }

    def _run(self):
        while not self.closed:
            self.wake.wait(0.5)
            self.wake.clear()
            with self.lock:
                job = next(
                    (
                        j
                        for j in self.jobs
                        if j["status"] == "queued" and (not self.paused or j.get("kind"))
                    ),
                    None,
                )
                if job is None:
                    continue
                job["status"] = "running"
                self.persist()
            try:
                if job.get("kind") == "install":
                    self.engine.install(lambda value: self._progress(job, value))
                elif job.get("kind") == "start-engine":
                    self.engine.request(
                        {
                            "snapshot": job["snapshot"],
                            "validate_only": True,
                            "device": self.engine.settings()
                            .get("runtime", {})
                            .get("device", "cpu"),
                        }
                    )
                else:
                    self._generate(job)
                with self.lock:
                    if job["status"] == "running":
                        job["status"] = "ready"
            except Exception as error:
                with self.lock:
                    if job["status"] == "running":
                        job.update(status="failed", error=str(error))
                        if "out of memory" in str(error).lower() or "引擎已停止" in str(error):
                            self.paused = True
            finally:
                with self.lock:
                    self.persist()
                self.wake.set()

    def submit(self, data):
        from types import SimpleNamespace

        import soundfile as sf

        from .voices import original, safe_audio_name

        entries = data.get("entries", [])
        if not isinstance(entries, list) or not 1 <= len(entries) <= 500:
            raise CliError("请选择1～500条源音频。")
        snapshot = self.engine.catalog.snapshot()
        checked = []
        for entry in entries:
            target = entry.get("target")
            if target:
                tools = Path(
                    os.environ.get(
                        "FH_RADIO_STUDIO_AUDIO_TOOLS_DIR",
                        self.engine.home.parents[1] / "tools/audio",
                    )
                )
                settings = _read(self.project / ".fh-radio-studio/project.json", {}).get(
                    "settings", {}
                )
                args = SimpleNamespace(
                    vgmstream_cli=str(tools / "vgmstream/vgmstream-cli.exe"),
                    game_dir=settings.get("game_dir") or str(self.project / "reference-game"),
                )
                path = Path(
                    original(
                        args,
                        self.project,
                        target["bank_id"],
                        target["index"],
                        entry.get("voice_language"),
                    )["path"]
                )
            else:
                path = Path(entry.get("path", "")).resolve()
            if not path.is_file():
                raise CliError("源音频不存在。")
            info = sf.info(path)
            if info.duration <= 0:
                raise CliError(f"源音频为空：{path.name}")
            identity = uuid.uuid4().hex
            folder = self.folder / identity
            source = folder / ("source" + path.suffix.lower())
            _copy_snapshot(path, source)
            name = str(entry.get("name") or path.stem)
            checked.append(
                {
                    "id": identity,
                    "status": "queued",
                    "origin": data.get("origin", "studio"),
                    "name": name,
                    "text": name,
                    "target": target,
                    "source": str(source),
                    "source_sha256": digest(source),
                    "snapshot": snapshot,
                    "preset": {"name": snapshot["model"]["filename"]},
                    "parameters": snapshot["parameters"],
                    "engine_name": "RVC",
                    "engine_revision": REVISION,
                    "count": 1,
                    "candidates": [],
                    "created_at": time.time(),
                    "device": self.engine.settings().get("runtime", {}).get("device", "cpu"),
                }
            )
        with self.lock:
            self.jobs.extend(checked)
            self.paused = False
            self.persist()
        self.wake.set()
        return self.status()

    def _generate(self, job):
        from .voices import safe_audio_name

        path = Path(job["source"])
        if not path.is_file() or digest(path) != job["source_sha256"]:
            raise CliError("源音频已变化，未开始转换。")
        for kind in ("model", "index"):
            record = job["snapshot"].get(kind)
            if record and digest(Path(record["absolute_path"])) != record["id"]:
                raise CliError("音色或索引已变化，请重新提交。")
        output = self.folder / job["id"] / (safe_audio_name(job["name"], 32) + "_RVC.wav")
        started = time.monotonic()
        result = self.engine.request(
            {
                "snapshot": job["snapshot"],
                "input": str(path),
                "output": str(output),
                "device": job["device"],
            },
            lambda value: self._progress(job, f"转换音色 · {value['stage']}"),
        )
        with self.lock:
            if job["status"] == "cancelled" or self.closed:
                output.unlink(missing_ok=True)
                return
            job["candidates"] = [
                {
                    "id": uuid.uuid4().hex,
                    **result,
                    "seed": 0,
                    "parameters": job["parameters"],
                    "seconds": time.monotonic() - started,
                    "checked": True,
                }
            ]

    def action(self, action, data):
        catalog = self.engine.catalog
        if action in ("save-preset", "select-preset", "delete-preset"):
            if any(j["status"] in ("running", "queued") for j in self.jobs):
                raise CliError("请先完成或停止当前任务。")
            if action == "save-preset":
                catalog.save_preset(data.get("name"), data.get("id"))
            elif action == "select-preset":
                catalog.select_preset(data.get("id"))
                self.engine.stop()
            else:
                catalog.delete_preset(data.get("id"))
            return self.status()
        if action == "configure-downloads":
            if any(
                j.get("kind") == "install" and j["status"] in ("running", "queued")
                for j in self.jobs
            ):
                raise CliError("请先暂停安装，再切换下载源。")
            sources = rvc_download_settings(data)
            with exclusive_file_lock(self.engine.home / "catalog.lock"):
                settings = catalog.read()
                settings["downloads"] = sources
                _write(catalog.path, settings)
            return self.status()
        if action == "configure-runtime":
            if any(j["status"] in ("running", "queued") for j in self.jobs):
                raise CliError("请先停止当前任务。")
            device = data.get("device", "cpu")
            if device not in ("cpu", "cuda:0"):
                raise CliError("无效的推理设备。")
            self.engine.stop()
            with exclusive_file_lock(self.engine.home / "catalog.lock"):
                settings = catalog.read()
                settings["runtime"] = {"device": device}
                _write(catalog.path, settings)
            return self.status()
        if action == "import-input":
            from .metadata import read_track_metadata
            from .voices import safe_audio_name

            inputs = _read(self.folder / "inputs.json", [])
            for filename in data.get("paths", []):
                source = Path(filename).resolve()
                if not source.is_file():
                    raise CliError("源音频不存在。")
                meta = read_track_metadata(source)
                duration = meta.duration_sec or 0
                if duration <= 0:
                    raise CliError(f"无法读取源音频：{source.name}")
                checksum = digest(source)
                if any(i["id"] == checksum for i in inputs):
                    continue
                target = (
                    self.folder
                    / "inputs"
                    / f"{safe_audio_name(source.stem, 40)}_{checksum[:8]}{source.suffix.lower()}"
                )
                _copy_snapshot(source, target)
                inputs.append(
                    {"id": checksum, "name": source.stem, "path": str(target), "duration": duration}
                )
            _write(self.folder / "inputs.json", inputs)
            return self.status()
        if action == "clear-inputs":
            for item in _read(self.folder / "inputs.json", []):
                path = Path(item["path"])
                if path.resolve().is_relative_to((self.folder / "inputs").resolve()):
                    path.unlink(missing_ok=True)
            _write(self.folder / "inputs.json", [])
            return self.status()
        if action == "import-file":
            result = catalog.import_file(data.get("path", ""), data.get("kind"))
            return {**self.status(), "imported_file": result}
        if action == "select-model":
            catalog.select_model(data.get("model_id"), data.get("index_id"))
            return self.status()
        if action == "save-parameters":
            catalog.save_parameters(data)
            return self.status()
        if action in ("check-engine", "check-installation"):
            return self.status()
        if action in ("start-engine", "restart-engine"):
            if any(j["status"] in ("running", "queued") for j in self.jobs):
                raise CliError("请先完成当前任务。")
            if action == "restart-engine":
                self.engine.stop()
            with self.lock:
                self.jobs.append(
                    {
                        "id": uuid.uuid4().hex,
                        "kind": "start-engine",
                        "snapshot": catalog.snapshot(),
                        "status": "queued",
                    }
                )
                self.persist()
            self.wake.set()
            return self.status()
        if action == "open-install-directory":
            self.engine.home.mkdir(parents=True, exist_ok=True)
            return {"path": str(self.engine.home)}
        if action == "engine-logs":
            path = self.engine.home / "engine.log"
            return {
                "text": (
                    path.read_text(encoding="utf-8", errors="replace")[-32000:]
                    if path.exists()
                    else ""
                )
            }
        if action == "uninstall-engine":
            if any(j["status"] in ("running", "queued") for j in self.jobs):
                raise CliError("请先停止任务。")
            self.engine.uninstall()
            return self.status()
        if action == "delete-model":
            if any(j["status"] in ("running", "queued", "paused") for j in self.jobs):
                raise CliError("请先完成或取消转换任务。")
            self.engine.stop()
            with exclusive_file_lock(self.engine.home / "catalog.lock"):
                settings = catalog.read()
                record = next((r for r in settings["files"] if r["id"] == data.get("id")), None)
                if record:
                    catalog.owned_file(record).unlink(missing_ok=True)
                    settings["files"].remove(record)
                    if record["kind"] == "index":
                        if settings.get("selection", {}).get("index_id") == record["id"]:
                            settings["selection"]["index_id"] = None
                    elif settings.get("selection", {}).get("model_id") == record["id"]:
                        settings.pop("selection", None)
                    _write(catalog.path, settings)
            return self.status()
        if action == "accept":
            data = {"category": "音色转换", **data}
        return super().action(action, data)


def cmd_rvc_workspace(args):
    project = Path(args.project_dir).resolve()
    if not (project / ".fh-radio-studio/project.json").is_file():
        raise CliError("请先打开工程。")
    home = (
        Path(args.engine_home)
        if args.engine_home
        else Path(
            os.environ.get("FH_RADIO_STUDIO_TOOLCHAIN_HOME", project / ".fh-radio-studio/toolchain")
        )
        / "engines/rvc"
    )
    with exclusive_file_lock(project / ".fh-radio-studio/rvc.lock"):
        workspace = RvcWorkspace(project, RvcEngine(home))
        try:
            if args.action == "serve":
                for line in sys.stdin:
                    message = {}
                    try:
                        message = json.loads(line)
                        response = {
                            "id": message["id"],
                            "result": workspace.action(
                                message["action"], message.get("input") or {}
                            ),
                        }
                    except Exception as error:
                        response = {"id": message.get("id"), "error": str(error)}
                    print(json.dumps(response, ensure_ascii=False), flush=True)
            else:
                data = json.load(sys.stdin) if args.input_json == "-" else {}
                result = workspace.action(args.action, data)
                if args.wait:
                    while any(
                        j["status"] in ("queued", "running") for j in workspace.status()["jobs"]
                    ):
                        time.sleep(0.2)
                    result = workspace.status()
                print(json.dumps(result, ensure_ascii=False))
        finally:
            workspace.close()
    return 0
