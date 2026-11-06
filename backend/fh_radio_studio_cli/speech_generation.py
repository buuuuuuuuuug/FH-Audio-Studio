"""Project-owned synthesis jobs and a separately managed official GPT-SoVITS.

The control loop never waits for inference. Only accepted WAVs enter the normal
voice asset plan; a job target is a snapshot, never a mutable table row number.
"""

from __future__ import annotations

import contextlib
import hashlib
import importlib.resources
import json
import math
import os
import random
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tarfile
import threading
import time
import urllib.request
import uuid
import zipfile
from pathlib import Path
from types import SimpleNamespace

from .common import CliError
from .file_lock import exclusive_file_lock
from .speech_api import SpeechApi
from .speech_downloads import download_candidates, download_settings, mirrored_runtime
from .stingers import _copy_snapshot, _write, digest

REVISION = "04a44eb977586645f33594b72af13a035a2056c6"
ARCHIVE_SHA256 = "21c421dc7734e276433787008f097b871041b1e11b2855b64df23492aeaf6467"
VERSIONS = ("v1", "v2", "v2Pro", "v2ProPlus", "v3", "v4", "v5dev", "v5turbo")
BASE_MODELS = {
    "chinese-hubert-base": ["config.json", "preprocessor_config.json", "pytorch_model.bin"],
    "chinese-roberta-wwm-ext-large": ["config.json", "tokenizer.json", "pytorch_model.bin"],
    "sv": ["pretrained_eres2netv2w24s4ep4.ckpt"],
    "fast_langdetect": ["lid.176.bin"],
}
# Source, Python environment, each base file, Japanese dictionary, three NLTK
# resources, and final verification. Keep progress tied to the actual checklist.
INSTALL_STEPS = 2 + sum(map(len, BASE_MODELS.values())) + 1 + 3 + 1
DEFAULTS = {
    "top_k": 15,
    "top_p": 1.0,
    "temperature": 1.0,
    "speed_factor": 1.0,
    "repetition_penalty": 1.35,
    "seed": -1,
    "text_split_method": "cut1",
    "batch_size": 1,
    "batch_threshold": 0.75,
    "split_bucket": False,
    "parallel_infer": False,
    "fragment_interval": 0.3,
    "sample_steps": 32,
    "super_sampling": False,
    "no_prompt": False,
    "device": "cuda",
    "is_half": True,
    "cfg_rate": 0.0,
    "streaming_mode": 0,
    "overlap_length": 2,
    "min_chunk_length": 16,
    "gpt_streaming": False,
    "streaming_chunk_seconds": 2.0,
    "streaming_window_mode": "fixed",
    "streaming_lookahead_seconds": 0.12,
    "streaming_overlap_seconds": 0.04,
    "gpt_streaming_lookahead_seconds": 0.5,
    "use_flash_attention": False,
}
LANGUAGES = {
    "auto",
    "auto_yue",
    "en",
    "zh",
    "ja",
    "yue",
    "ko",
    "all_zh",
    "all_ja",
    "all_yue",
    "all_ko",
}


def parameters(data, version="v2ProPlus"):
    defaults = {**DEFAULTS}
    if version == "v5dev":
        defaults["cfg_rate"] = 1.3
    if version == "v5turbo":
        defaults["sample_steps"] = 4
    result = {**defaults, **{k: v for k, v in data.items() if k in DEFAULTS}}
    for key, low, high in (
        ("top_k", 1, 100),
        ("top_p", 0.01, 1),
        ("temperature", 0.01, 1),
        ("speed_factor", 0.1, 3),
        ("repetition_penalty", 0.01, 5),
        ("seed", -1, 2**32 - 1),
        ("batch_size", 1, 200),
        ("batch_threshold", 0, 1),
        ("fragment_interval", 0.01, 1),
        ("cfg_rate", 0, 2),
        ("overlap_length", 1, 32),
        ("min_chunk_length", 4, 256),
        ("streaming_chunk_seconds", 0.2, 10),
        ("streaming_lookahead_seconds", 0, 2),
        ("streaming_overlap_seconds", 0, 1),
        ("gpt_streaming_lookahead_seconds", 0, 2),
    ):
        value = result[key]
        if type(value) not in (float, int) or not math.isfinite(value) or not low <= value <= high:
            raise CliError(f"推理参数 {key} 超出范围（{low}–{high}）。")
    for key in ("top_k", "seed", "batch_size", "overlap_length", "min_chunk_length"):
        if int(result[key]) != result[key]:
            raise CliError(f"推理参数 {key} 必须为整数。")
        result[key] = int(result[key])
    for key, default in DEFAULTS.items():
        if type(default) is bool and type(result[key]) is not bool:
            raise CliError(f"推理参数 {key} 必须为开关值。")
    if result["sample_steps"] not in (4, 8, 16, 32):
        raise CliError("采样步数只能选择 4、8、16、32。")
    if result["text_split_method"] not in {f"cut{i}" for i in range(6)}:
        raise CliError("文本切分方式无效。")
    if result["device"] not in ("cuda", "cpu"):
        raise CliError("请选择 CUDA 或 CPU。")
    if result["streaming_mode"] not in (0, 1, 2, 3):
        raise CliError("流式试听模式无效。")
    if result["streaming_window_mode"] not in ("fixed", "hybrid"):
        raise CliError("流式窗口模式无效。")
    if result["gpt_streaming"] and (
        version not in ("v2ProPlus", "v5dev", "v5turbo")
        or result["batch_size"] != 1
        or result["streaming_mode"] not in (2, 3)
    ):
        raise CliError("语义流式需使用 v2ProPlus/V5、批次 1 和流式模式 2 或 3。")
    # Never pretend unsupported, imported options are effective.
    if version != "v3":
        result["super_sampling"] = False
    if version not in ("v3", "v4", "v5dev", "v5turbo"):
        result["sample_steps"] = 32
    if version not in ("v5dev", "v5turbo"):
        result["cfg_rate"] = 0.0
    if version in ("v3", "v4", "v5dev", "v5turbo"):
        result["no_prompt"] = False
    return result


def _read(path, default):
    if not path.is_file():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise CliError(f"无法读取生成记录，原文件已保留：{path.name}") from error


def _uv():
    value = os.environ.get("FH_RADIO_STUDIO_UV_EXE") or shutil.which("uv")
    if not value:
        raise CliError("未找到应用自带的 uv，请修复处理组件。")
    return str(value)


class Engine:
    def __init__(self, home: Path):
        self.home = home.resolve()
        self.source = self.home / f"GPT-SoVITS-{REVISION}"
        self.environment = self.home / "environment"
        self.config_path = self.home / "settings.json"
        self.process = None
        self.active_preset = None
        self.log = None
        self.lease = None
        self.interrupted = threading.Event()
        self._owned_cache = {}
        self._download_progress = None
        self._download_response = None
        self._install_stage = None
        self.api = SpeechApi(self)

    def settings(self):
        return _read(self.config_path, {"schema_version": 1, "presets": []})

    def components(self):
        base = self.source / "GPT_SoVITS/pretrained_models"
        checks = {
            "官方源码": [self.source / "GPT_SoVITS/TTS_infer_pack/TTS.py"],
            "Python 依赖": [
                self.environment / "Lib/site-packages" / name / "__init__.py"
                for name in (
                    "fastapi",
                    "uvicorn",
                    "python_multipart",
                    "torch",
                    "transformers",
                    "librosa",
                )
            ],
            "基础模型": [
                base / folder / name for folder, names in BASE_MODELS.items() for name in names
            ],
            "发音词典": [
                self.home / "open_jtalk_dic_utf_8-1.11/sys.dic",
                self.home / "nltk_data/corpora/cmudict",
                self.home / "nltk_data/taggers/averaged_perceptron_tagger",
                self.home / "nltk_data/taggers/averaged_perceptron_tagger_eng",
            ],
        }
        return [
            {
                "name": name,
                "ready": all(path.exists() for path in paths),
                "missing": [
                    str(path.relative_to(self.home)) for path in paths if not path.exists()
                ],
            }
            for name, paths in checks.items()
        ]

    def status(self):
        settings = self.settings()
        components = self.components()
        installed = (self.home / "installation.json").is_file() and all(
            c["ready"] for c in components
        )
        return {
            "installed": installed,
            "components": components,
            "downloads": download_settings(settings.get("downloads")),
            "api_dependencies_ready": all(
                (self.environment / "Lib/site-packages" / name / "__init__.py").is_file()
                for name in ("fastapi", "uvicorn", "python_multipart")
            ),
            "api": self.api.status(),
            "connection": self.api.connection,
            "source_ready": (self.source / "GPT_SoVITS/TTS_infer_pack/TTS.py").is_file(),
            "revision": REVISION,
            "home": str(self.home),
            "running": self.api.status()["owned"]
            or (self.process is not None and self.process.poll() is None),
            "presets": settings.get("presets", []),
            "defaults": DEFAULTS,
            "log": str(self.home / "engine.log"),
        }

    def environment_vars(self):
        env = dict(os.environ)
        env.update(
            UV_PROJECT_ENVIRONMENT=str(self.environment),
            PYTHONIOENCODING="utf-8",
            PYTHONUTF8="1",
            PYTHONUNBUFFERED="1",
            TrackFileAccess="false",
            HF_HUB_OFFLINE="1",
            TRANSFORMERS_OFFLINE="1",
            HF_HUB_DISABLE_TELEMETRY="1",
            TOKENIZERS_PARALLELISM="false",
            NLTK_DATA=str(self.home / "nltk_data"),
            OPEN_JTALK_DICT_DIR=str(self.home / "open_jtalk_dic_utf_8-1.11"),
        )
        env.pop("VIRTUAL_ENV", None)
        tools = Path(
            env.get("FH_RADIO_STUDIO_AUDIO_TOOLS_DIR", self.home.parents[1] / "tools/audio")
        )
        env["PATH"] = str(tools / "ffmpeg") + os.pathsep + env.get("PATH", "")
        return env

    def _installation_log(self, message):
        self.home.mkdir(parents=True, exist_ok=True)
        with (self.home / "engine.log").open("a", encoding="utf-8") as stream:
            stream.write(message + "\n")

    def _stage(self, progress, completed, label):
        self._installation_log(label)
        if self._install_stage is None:
            progress(label)
            return
        self._install_stage = {
            "completed": completed,
            "total": INSTALL_STEPS,
            "fraction": completed / INSTALL_STEPS,
            "stage": label,
        }
        progress({"progress": label, "installation": dict(self._install_stage), "download": None})

    def install(self, progress):
        self._install_stage = {"completed": 0, "total": INSTALL_STEPS}
        self._download_progress = progress
        try:
            self._install(progress)
        finally:
            self._download_progress = None
            self._install_stage = None

    def _install(self, progress):
        self.api.stop()
        self.interrupted.clear()
        self.home.mkdir(parents=True, exist_ok=True)
        self._stage(progress, 0, "下载并校验官方引擎")
        if not (self.source / "GPT_SoVITS/TTS_infer_pack/TTS.py").is_file():
            archive = self.home / "official.zip"
            temporary = self.home / "official.zip.part"
            if not archive.is_file():
                self.download(
                    f"https://codeload.github.com/RVC-Boss/GPT-SoVITS/zip/{REVISION}", temporary
                )
                temporary.replace(archive)
            if digest(archive) != ARCHIVE_SHA256:
                raise CliError("官方源码压缩包校验失败，未解压；请移除损坏的 official.zip 后重试。")
            with zipfile.ZipFile(archive) as zipped:
                root = self.home.resolve()
                for member in zipped.infolist():
                    target = (root / member.filename).resolve()
                    if root not in target.parents or member.is_dir() and target == root:
                        raise CliError("官方压缩包包含无效路径。")
                zipped.extractall(root)
        self._stage(progress, 1, "同步独立推理环境（首次需要下载依赖）")
        resources = importlib.resources.files("backend.fh_radio_studio_cli.tts_runtime")
        runtime_project = self.home / "runtime"
        runtime_project.mkdir(exist_ok=True)
        sources = download_settings(self.settings().get("downloads"))
        project_text, lock_text = mirrored_runtime(
            resources.joinpath("pyproject.toml").read_text(encoding="utf-8"),
            resources.joinpath("uv.lock").read_text(encoding="utf-8"),
            sources,
        )
        (runtime_project / "pyproject.toml").write_text(project_text, encoding="utf-8")
        (runtime_project / "uv.lock").write_text(lock_text, encoding="utf-8")
        self.log = (self.home / "engine.log").open("a", encoding="utf-8")
        env = self.environment_vars()
        # Installation can download; inference itself remains offline.
        env.pop("HF_HUB_OFFLINE", None)
        env.pop("TRANSFORMERS_OFFLINE", None)
        env.pop("UV_OFFLINE", None)
        env.pop("UV_NO_PROGRESS", None)
        env["UV_NATIVE_TLS"] = "true"
        env["UV_DEFAULT_INDEX"] = sources["pypi"]
        process = self.process = subprocess.Popen(
            [
                _uv(),
                "sync",
                "--verbose",
                "--color",
                "never",
                "--project",
                str(runtime_project),
                "--python",
                "3.12",
                *(["--frozen"] if (runtime_project / "uv.lock").is_file() else []),
            ],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=self.log,
            stderr=self.log,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        code = process.wait()
        self.process = None
        if self.log:
            self.log.close()
            self.log = None
        if code or self.interrupted.is_set():
            raise CliError("独立环境安装未完成，请查看引擎日志后重试。")
        self.prepare_base_models(progress)
        self._stage(progress, 13, "校验引擎组件")
        missing = [c["name"] for c in self.components() if not c["ready"]]
        if missing:
            raise CliError("安装尚未完成：" + "、".join(missing) + "；请继续安装。")
        self.api._set("stopped", "引擎安装完成；下一步配置声音模型和参考音频。")
        _write(self.home / "installation.json", {"revision": REVISION, "installed_at": time.time()})
        self._stage(progress, INSTALL_STEPS, "引擎环境已安装；导入声音预设后可以生成")

    def prepare_base_models(self, progress):
        base = self.source / "GPT_SoVITS/pretrained_models"
        required = BASE_MODELS
        entries = [(folder, name) for folder, names in required.items() for name in names]
        for index, (folder, name) in enumerate(entries, start=2):
            if self.interrupted.is_set():
                raise CliError("安装已取消，已完成的下载保留。")
            self._stage(progress, index, f"准备基础模型：{folder}/{name}")
            target = base / folder / name
            if not target.is_file():
                target.parent.mkdir(parents=True, exist_ok=True)
                temporary = target.with_suffix(target.suffix + ".part")
                url = (
                    "https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.bin"
                    if folder == "fast_langdetect"
                    else f"https://huggingface.co/lj1995/GPT-SoVITS/resolve/main/{folder}/{name}"
                )
                self.download(url, temporary)
                temporary.replace(target)
            self._stage(progress, index + 1, f"已准备基础模型：{folder}/{name}")

        dictionary = self.home / "open_jtalk_dic_utf_8-1.11"
        self._stage(progress, 2 + len(entries), "准备日语发音词典")
        if not (dictionary / "sys.dic").is_file():
            archive = self.home / "open_jtalk_dictionary.tar.gz"
            self.download(
                "https://github.com/r9y9/open_jtalk/releases/download/v1.11.1/open_jtalk_dic_utf_8-1.11.tar.gz",
                archive,
            )
            with tarfile.open(archive) as packaged:
                packaged.extractall(self.home, filter="data")
        self._stage(progress, 3 + len(entries), "日语发音词典已准备")
        for index, (kind, name) in enumerate(
            (
                ("corpora", "cmudict"),
                ("taggers", "averaged_perceptron_tagger"),
                ("taggers", "averaged_perceptron_tagger_eng"),
            ),
            start=3 + len(entries),
        ):
            self._stage(progress, index, f"准备英语发音数据：{name}")
            folder = self.home / "nltk_data" / kind
            if (folder / name).is_dir():
                self._stage(progress, index + 1, f"已准备英语发音数据：{name}")
                continue
            folder.mkdir(parents=True, exist_ok=True)
            archive = folder / f"{name}.zip"
            self.download(
                f"https://raw.githubusercontent.com/nltk/nltk_data/gh-pages/packages/{kind}/{name}.zip",
                archive,
            )
            with zipfile.ZipFile(archive) as packaged:
                for member in packaged.infolist():
                    if folder.resolve() not in (folder / member.filename).resolve().parents:
                        raise CliError("发音数据包含无效路径。")
                packaged.extractall(folder)
            self._stage(progress, index + 1, f"已准备英语发音数据：{name}")

    def download(self, url, target):
        failures = []
        sources = download_settings(self.settings().get("downloads"))
        for attempt, address in enumerate(download_candidates(url, sources)):
            if self.interrupted.is_set():
                raise CliError("安装已暂停，已下载内容保留。")
            try:
                return self._download_once(address, target, restart=attempt > 0)
            except CliError as error:
                if self.interrupted.is_set():
                    raise
                failures.append(str(error))
                self._installation_log(f"下载源未成功：{address}；{error}")
        raise CliError("下载源均未成功：" + "；".join(failures))

    def _download_once(self, address, target, *, restart=False):
        target = Path(target)
        target.parent.mkdir(parents=True, exist_ok=True)
        # Alternate archives may encode identical contents differently. Never
        # append another source's bytes to a partially downloaded archive.
        offset = target.stat().st_size if target.exists() and not restart else 0
        request = urllib.request.Request(
            address, headers={"Range": f"bytes={offset}-"} if offset else {}
        )
        context = ssl.create_default_context()
        # Preserve Windows/system trust and supplement it with the CA bundle
        # already installed with requests in the inference environment.
        bundle = self.environment / "Lib/site-packages/certifi/cacert.pem"
        if bundle.is_file():
            context.load_verify_locations(cafile=str(bundle))
        try:
            with urllib.request.urlopen(request, timeout=60, context=context) as response:
                self._download_response = response
                resumed = offset > 0 and response.status == 206
                if resumed and not response.headers.get("Content-Range", "").startswith(
                    f"bytes {offset}-"
                ):
                    raise CliError("下载源返回了错误的续传位置，请切换下载源。")
                received = offset if resumed else 0
                length = int(response.headers.get("Content-Length", "0"))
                total = received + length if length else None
                last = time.monotonic()
                last_received = received
                reported = -1

                def report(now):
                    nonlocal last, last_received, reported
                    if not self._download_progress:
                        return
                    elapsed = max(now - last, 0.001)
                    rate = max(0, received - last_received) / elapsed
                    value = {
                        "progress": f"下载 {target.name} · {received / 1048576:.1f} MiB"
                        + (f" / {total / 1048576:.1f} MiB" if total else ""),
                        "download": {
                            "received": received,
                            "total": total,
                            "fraction": received / total if total else None,
                            "bytes_per_second": rate,
                        },
                    }
                    if self._install_stage is not None:
                        value["installation"] = {
                            **self._install_stage,
                            "fraction": (
                                self._install_stage["completed"]
                                + (received / total if total else 0)
                            )
                            / self._install_stage["total"],
                        }
                    self._download_progress(value)
                    self._installation_log(f"{value['progress']} · {rate / 1048576:.2f} MiB/s")
                    last, last_received, reported = now, received, received

                with target.open("ab" if resumed else "wb") as stream:
                    while True:
                        if self.interrupted.is_set():
                            raise CliError("安装已暂停，已下载内容保留；返回后点击继续安装。")
                        block = response.read(256 * 1024)
                        if not block:
                            break
                        stream.write(block)
                        received += len(block)
                        now = time.monotonic()
                        if now - last >= 0.5 or total and received == total:
                            report(now)
                if reported != received:
                    report(time.monotonic())
                if total and received != total:
                    raise CliError("下载未完成，已保留进度，请继续安装。")
        except urllib.error.HTTPError as error:
            # A completed .part can survive a crash just before rename.
            if (
                error.code == 416
                and offset
                and error.headers.get("Content-Range") == f"bytes */{offset}"
            ):
                return
            raise CliError(
                f"下载失败：{target.name}（HTTP {error.code}）。地址：{address}；可切换下载源后继续安装。"
            ) from error
        except (OSError, TimeoutError) as error:
            if isinstance(getattr(error, "reason", error), ssl.SSLError):
                raise CliError(
                    f"证书校验失败：{address}。请检查系统时间及代理证书；未关闭 HTTPS 校验。{error}"
                ) from error
            raise CliError(
                f"下载中断：{target.name}，已保留部分文件。请检查网络或切换下载源后继续。{error}"
            ) from error

    def uninstall(self):
        """Remove the owned runtime, retaining imported voices and presets."""
        self.stop()
        if (
            self.home.name != "gpt-sovits"
            or self.home.is_symlink()
            or getattr(self.home, "is_junction", lambda: False)()
        ):
            raise CliError("引擎目录无效，未删除文件。")
        names = [
            self.source.name,
            "environment",
            "runtime",
            "nltk_data",
            "open_jtalk_dic_utf_8-1.11",
            "official.zip",
            "official.zip.part",
            "open_jtalk_dictionary.tar.gz",
            "installation.json",
            "api-config.yaml",
        ]
        paths = [self.home / name for name in names]
        for path in paths:
            if (
                path.is_symlink()
                or getattr(path, "is_junction", lambda: False)()
                or not path.resolve().is_relative_to(self.home)
            ):
                raise CliError("引擎目录包含外部链接，未删除文件。")
        for path in paths:
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink(missing_ok=True)
        self.api._set("unconfigured", "推理引擎已删除，声音预设和导入文件保留。")

    def prepare_family_models(self, version, progress):
        """Only fetch the extra vocoder/base needed by the selected family."""
        files = []
        if version == "v3":
            files = [
                ("s2Gv3.pth", "lj1995/GPT-SoVITS", "s2Gv3.pth"),
                (
                    "models--nvidia--bigvgan_v2_24khz_100band_256x/config.json",
                    "nvidia/bigvgan_v2_24khz_100band_256x",
                    "config.json",
                ),
                (
                    "models--nvidia--bigvgan_v2_24khz_100band_256x/bigvgan_generator.pt",
                    "nvidia/bigvgan_v2_24khz_100band_256x",
                    "bigvgan_generator.pt",
                ),
            ]
        elif version == "v4" or version.startswith("v5"):
            folder = "gsv-v5-pretrained" if version.startswith("v5") else "gsv-v4-pretrained"
            files = [
                (f"{folder}/vocoder.pth", "lj1995/GPT-SoVITS", f"{folder}/vocoder.pth"),
                (f"{folder}/s2G{version}.pth", "lj1995/GPT-SoVITS", f"{folder}/s2G{version}.pth"),
            ]
        for relative, repository, name in files:
            target = self.source / "GPT_SoVITS/pretrained_models" / relative
            if target.is_file():
                continue
            progress(f"首次准备 {version} 基础组件：{name}（需要网络）")
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_suffix(target.suffix + ".part")
            self.download(f"https://huggingface.co/{repository}/resolve/main/{name}", temporary)
            temporary.replace(target)

    def _owned_file(self, source, folder, filename=None):
        path = Path(source).expanduser().resolve()
        if not path.is_file():
            raise CliError(f"文件不存在：{path.name}")
        if path.is_relative_to((self.home / folder).resolve()) and filename is None:
            return str(path.relative_to(self.home).as_posix())
        stat = path.stat()
        signature = (str(path), stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns)
        checksum = self._owned_cache.get(signature)
        if checksum is None:
            checksum = digest(path)
            if len(self._owned_cache) >= 128:
                self._owned_cache.clear()
            self._owned_cache[signature] = checksum
        from .voices import safe_audio_name

        target = (
            self.home
            / folder
            / f"{safe_audio_name(Path(filename or path.name).stem, 60)}_{checksum[:8]}{path.suffix.lower()}"
        )
        if target != path and not target.is_file():
            _copy_snapshot(path, target)
        return target.relative_to(self.home).as_posix()

    def import_file(self, kind, value):
        if kind not in ("gpt_model", "sovits_model", "ref_audio_path", "aux_ref_audio"):
            raise CliError("不支持的导入类型。")
        source = Path(value).expanduser().resolve()
        if not source.is_file():
            raise CliError("导入文件不存在。")
        model = kind in ("gpt_model", "sovits_model")
        allowed = (
            (".ckpt",)
            if kind == "gpt_model"
            else (".pth",) if model else (".wav", ".flac", ".ogg", ".mp3")
        )
        if source.suffix.lower() not in allowed:
            raise CliError("请选择对应类型的模型或音频文件。")
        original = source.name
        if not model:
            from .stingers import _run

            folder = self.home / "references"
            folder.mkdir(parents=True, exist_ok=True)
            temporary = folder / f"import-{uuid.uuid4().hex}.wav"
            tools = Path(
                os.environ.get(
                    "FH_RADIO_STUDIO_AUDIO_TOOLS_DIR", self.home.parents[1] / "tools/audio"
                )
            )
            try:
                _run(
                    [
                        str(tools / "ffmpeg" / ("ffmpeg.exe" if os.name == "nt" else "ffmpeg")),
                        "-v",
                        "error",
                        "-y",
                        "-i",
                        str(source),
                        "-acodec",
                        "pcm_s16le",
                        str(temporary),
                    ]
                )
                import soundfile as sf

                info = sf.info(temporary)
                if info.frames <= 0 or kind == "ref_audio_path" and not 3 <= info.duration <= 10:
                    raise CliError("主参考音频应为 3–10 秒；请选择有效音频。")
                owned = self._owned_file(temporary, "references", original)
            finally:
                temporary.unlink(missing_ok=True)
        else:
            owned = self._owned_file(source, "models")
        record = {"kind": kind, "path": owned, "filename": original}
        settings = self.settings()
        settings["imports"] = [
            item
            for item in settings.get("imports", [])
            if (item.get("kind"), item.get("path")) != (kind, owned)
        ] + [record]
        _write(self.config_path, settings)
        return record

    def prepare_models(self, data):
        version = data.get("version", "v2ProPlus")
        if version not in VERSIONS:
            raise CliError("请选择支持的模型版本。")
        result = {"version": version, "parameters": parameters(data.get("parameters", {}), version)}
        for key, extension in (("gpt_model", ".ckpt"), ("sovits_model", ".pth")):
            value = data.get(key)
            if not value:
                raise CliError("启动服务前请先导入 GPT 和 SoVITS 模型；参考音频仅在生成时需要。")
            path = Path(value)
            path = path if path.is_absolute() else self.home / path
            if path.suffix.lower() != extension or not path.is_file():
                raise CliError("模型文件不可用，请重新导入 GPT 和 SoVITS 模型。")
            result[key] = self._owned_file(path, "models")
        return result

    def prepare_config(self, data):
        import soundfile as sf

        name = str(data.get("name", "")).strip()
        version = data.get("version", "v2ProPlus")
        if not name or len(name) > 100 or version not in VERSIONS:
            raise CliError("预设名称或模型版本无效。")
        params = parameters(data.get("parameters", data), version)
        language = data.get("text_lang", "all_ja")
        prompt_language = data.get("prompt_lang", language)
        if language not in LANGUAGES or prompt_language not in LANGUAGES:
            raise CliError("预设语言无效。")
        if version == "v1" and (
            {language, prompt_language} - {"auto", "en", "zh", "ja", "all_zh", "all_ja"}
        ):
            raise CliError("V1 模型仅支持中文、日语、英语及对应混合模式。")
        reference = Path(data["ref_audio_path"])
        if not reference.is_absolute():
            reference = self.home / reference
        try:
            info = sf.info(reference)
        except (OSError, RuntimeError) as error:
            raise CliError("参考音频无法读取，请先转换成 WAV。") from error
        if not 3 <= info.duration <= 10:
            raise CliError(f"主参考音频应为 3–10 秒，当前为 {info.duration:.3f} 秒。")
        prompt = str(data.get("prompt_text", "")).strip()
        if not prompt and not params["no_prompt"]:
            raise CliError("请填写参考音频文本，或在支持的模型上启用无需参考文本模式。")

        def owned(value, folder):
            source = Path(value)
            return self._owned_file(source if source.is_absolute() else self.home / source, folder)

        def original_name(value, recorded=None):
            source = Path(value)
            # The managed digest is an identifier, never a recovered filename.
            if recorded and not (
                recorded == source.name and re.fullmatch(r"[0-9a-f]{64}\.[^.]+", recorded)
            ):
                return Path(recorded).name
            managed = source if source.is_absolute() else self.home / source
            if managed.resolve().is_relative_to(self.home):
                for item in self.settings().get("imports", []):
                    if (self.home / item.get("path", "")).resolve() == managed.resolve():
                        return Path(item["filename"]).name
                # A managed stem contains an internal digest suffix, not the
                # exact original name. Missing metadata must stay explicit.
                if re.search(r"_[0-9a-f]{8}\.[^.]+$", source.name):
                    return None
            if not re.fullmatch(r"[0-9a-f]{64}\.[^.]+", source.name):
                return source.name
            return None

        gpt_name = original_name(data["gpt_model"], data.get("gpt_filename"))
        sovits_name = original_name(data["sovits_model"], data.get("sovits_filename"))
        reference_name = original_name(reference, data.get("reference_filename"))
        auxiliary_names = data.get("aux_reference_filenames") or []
        preset = {
            "id": data.get("id") or uuid.uuid4().hex,
            "name": name,
            "version": version,
            "gpt_model": owned(data["gpt_model"], "models"),
            "sovits_model": owned(data["sovits_model"], "models"),
            "ref_audio_path": owned(reference, "references"),
            "aux_ref_audio_paths": [
                owned(v, "references") for v in data.get("aux_ref_audio_paths", [])
            ],
            "prompt_text": prompt,
            "prompt_lang": prompt_language,
            "text_lang": language,
            "parameters": params,
            "gpt_label": gpt_name,
            "gpt_filename": gpt_name,
            "sovits_label": sovits_name,
            "sovits_filename": sovits_name,
            "reference_label": reference_name,
            "reference_filename": reference_name,
            "aux_reference_filenames": [
                original_name(path, auxiliary_names[i] if i < len(auxiliary_names) else None)
                for i, path in enumerate(data.get("aux_ref_audio_paths", []))
            ],
        }
        return preset

    def save_preset(self, data):
        preset = self.prepare_config(data)
        settings = self.settings()
        if any(
            p["name"] == preset["name"] and p["id"] != preset["id"] for p in settings["presets"]
        ):
            raise CliError("此预设名称已存在，请使用其他名称，或选择原预设后保存。")
        settings["presets"] = [p for p in settings["presets"] if p["id"] != preset["id"]] + [preset]
        _write(self.config_path, settings)
        return preset

    def stop(self):
        self.interrupted.set()
        response, self._download_response = self._download_response, None
        if response:
            with contextlib.suppress(Exception):
                response.fp.raw._sock.shutdown(socket.SHUT_RDWR)
            with contextlib.suppress(Exception):
                response.close()
        self.api.stop()
        process, self.process = self.process, None
        if process and process.poll() is None:
            if os.name == "nt":
                subprocess.run(
                    ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                    capture_output=True,
                    creationflags=subprocess.CREATE_NO_WINDOW,
                )
            else:
                process.kill()
            with contextlib.suppress(subprocess.TimeoutExpired):
                process.wait(timeout=10)
        if self.log:
            self.log.close()
            self.log = None
        self.active_preset = None
        if self.lease:
            self.lease.__exit__(None, None, None)
            self.lease = None

    def generate(self, preset, text, language, params, output):
        if self.api.connection["mode"] == "managed" and not self.status()["installed"]:
            raise CliError("请先安装独立 GPT-SoVITS 引擎。")
        return self.api.generate(preset, text, language, params, output)


class GenerationWorkspace:
    def __init__(self, project, engine):
        self.project = Path(project).resolve()
        self.folder = self.project / "analysis/voices/generation"
        self.path = self.folder / "jobs.json"
        self.engine = engine
        self.lock = threading.RLock()
        self.jobs = _read(self.path, {"schema_version": 1, "jobs": []})["jobs"]
        for job in self.jobs:
            if job.get("auto_apply") and not job.get("consumed"):
                job["auto_apply"] = False
                job["notice"] = "生成结果保留为预览；请试听后点击替换音频。"
            job.pop("fit_duration", None)
            job.pop("target_duration", None)
            if job.pop("original_reference", False):
                job["notice"] = "游戏原音参考功能已移除，继续生成时使用原声音预设的参考音频。"
            if job["status"] in ("queued", "running"):
                job["status"] = (
                    "paused" if job.get("kind") == "install" or not job.get("kind") else "cancelled"
                )
            if job.get("kind") not in (None, "install") and job["status"] == "paused":
                job["status"] = "cancelled"
        self.paused = any(job["status"] == "paused" and not job.get("kind") for job in self.jobs)
        self.closed = False
        self.wake = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def persist(self):
        _write(self.path, {"schema_version": 1, "jobs": self.jobs})

    def status(self):
        with self.lock:
            return json.loads(
                json.dumps(
                    {
                        "engine": self.engine.status(),
                        "jobs": self.jobs,
                        "paused": self.paused,
                        "selected_preset_id": self.selected_preset(),
                        "imports": self.engine.settings().get("imports", []),
                    },
                    ensure_ascii=False,
                )
            )

    def selected_preset(self):
        path = self.folder / "selection.json"
        if path.is_file():
            return json.loads(path.read_text(encoding="utf-8")).get("preset_id")
        return None

    def delete_candidate(self, data):
        """Delete generated files only; user-imported originals are never removed."""
        from .voice_workspace import remove_assets
        from .voices import load_plan

        with self.lock:
            job, candidate = self._candidate(data)
            if job["status"] in ("running", "queued", "paused"):
                raise CliError("请先完成或取消当前生成任务。")
            source = Path(candidate["path"]).resolve()
            if not source.is_relative_to(self.folder.resolve()) or source.is_symlink():
                raise CliError("生成音频路径无效。")
            plan = load_plan(self.project)
            # One candidate may have been adopted repeatedly after edits.
            assets = [
                a
                for a in plan["assets"]
                if a.get("generation", {}).get("job_id") == job["id"]
                and (a.get("generation", {}).get("seed") == candidate.get("seed"))
            ]
            ids = [a["id"] for a in assets]
            from .stingers import local_file

            paths = {source}
            for asset in assets:
                owned = local_file(self.project, asset["source"]).resolve()
                if owned.is_relative_to((self.project / "sources/voices").resolve()):
                    paths.add(owned)
            # Check Windows file locks before changing saved mappings. Roll back
            # all renames if any file cannot be moved or the plan cannot be saved.
            staged = []
            try:
                for path in paths:
                    if path.exists():
                        trash = path.with_name(path.name + ".delete-" + uuid.uuid4().hex)
                        path.rename(trash)
                        staged.append((path, trash))
                if ids:
                    plan = remove_assets(self.project, {"assets": ids})["plan"]
            except OSError as error:
                for path, trash in reversed(staged):
                    trash.rename(path)
                raise CliError("音频正在播放或被占用，请停止试听后重试删除。") from error
            for _, trash in staged:
                trash.unlink(missing_ok=True)
            job["candidates"] = [c for c in job["candidates"] if c["id"] != candidate["id"]]
            if not job["candidates"]:
                job["preview_deleted"] = True
            if job.get("accepted") == candidate["id"]:
                for key in ("accepted", "asset_id", "adopted_edit", "consumed"):
                    job.pop(key, None)
            self.persist()
            return {**self.status(), "removed_asset_ids": ids, "plan": plan}

    def submit(self, data):
        preset = (
            self.engine.prepare_config(data["config"])
            if isinstance(data.get("config"), dict)
            else next(
                (p for p in self.engine.settings()["presets"] if p["id"] == data.get("preset_id")),
                None,
            )
        )
        if not preset:
            raise CliError("请选择声音预设。")
        entries = data.get("entries", [])
        count = data.get("count", data.get("candidate_count", 1))
        if (
            not isinstance(entries, list)
            or not entries
            or len(entries) > 500
            or type(count) is not int
            or not 1 <= count <= 8
        ):
            raise CliError("请选择文本并设置 1–8 次生成。")
        checked = []
        for entry in entries:
            entry_preset = (
                preset
                if "preset_id" not in entry
                else next(
                    (
                        p
                        for p in self.engine.settings()["presets"]
                        if p["id"] == entry.get("preset_id", preset["id"])
                    ),
                    None,
                )
            )
            if entry_preset is None:
                raise CliError("某条任务的声音预设不存在，请重新选择。")
            entry_params = parameters(
                {**entry_preset["parameters"], **data.get("parameters", {})},
                entry_preset["version"],
            )
            text = str(entry.get("text", "")).strip()
            language = entry.get("language", entry_preset["text_lang"])
            if not text or len(text) > 10000 or language not in LANGUAGES:
                raise CliError("生成文本不能为空、超过 10000 字或使用无效语言。")
            target = entry.get("target")
            if entry_preset["version"] == "v1" and language not in {
                "auto",
                "en",
                "zh",
                "ja",
                "all_zh",
                "all_ja",
            }:
                raise CliError("V1 模型仅支持中文、日语与英语。")
            if target:
                from .voices import load_plan

                bank = load_plan(self.project)["banks"].get(target.get("bank_id"))
                if (
                    not bank
                    or bank["sha256"] != target.get("sha256")
                    or type(target.get("index")) is not int
                    or not 0 <= target["index"] < bank["count"]
                ):
                    raise CliError("原资源或目标条目已变化，请重新选择。")
            checked.append(
                {
                    "id": uuid.uuid4().hex,
                    "status": "queued",
                    "text": text,
                    "language": language,
                    "name": text[:80],
                    "source_entry_name": str(entry.get("name", ""))[:200],
                    "target": target,
                    "origin": str(data.get("origin", "studio")),
                    "preset": json.loads(json.dumps(entry_preset)),
                    "parameters": entry_params,
                    "count": count,
                    "candidates": [],
                    "auto_apply": False,
                    "created_at": time.time(),
                }
            )
        with self.lock:
            if any(j["status"] in ("queued", "running") and j.get("kind") for j in self.jobs):
                raise CliError("引擎或预设正在准备，请完成后再生成。")
            # A fresh Generate action starts newly queued work. Restored tasks
            # retain their per-job paused status until explicitly resumed.
            self.paused = False
            self.jobs.extend(checked)
            self.persist()
        self.wake.set()
        return self.status()

    def _progress(self, job, value):
        with self.lock:
            if isinstance(value, dict):
                job.update(value)
            else:
                job["progress"] = value
                job.pop("download", None)
            self.persist()

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
                    self.engine.install(lambda s: self._progress(job, s))
                elif job.get("kind") in ("start-engine", "restart-engine"):
                    if job["kind"] == "restart-engine":
                        self.engine.api.stop()
                    self.engine.prepare_family_models(
                        job["preset"]["version"], lambda s: self._progress(job, s)
                    )
                    self.engine.api.start(job["preset"])
                else:
                    self._generate(job)
                with self.lock:
                    if not self.closed and job["status"] == "running":
                        job["status"] = "ready"
            except Exception as error:
                with self.lock:
                    if not self.closed and job["status"] == "running":
                        job.update(status="failed", error=str(error))
                        if job.get("kind"):
                            self.engine.api._set("error", str(error))
            finally:
                with self.lock:
                    self.persist()
                self.wake.set()

    def _generate(self, job):
        import numpy as np
        import soundfile as sf

        from .voices import safe_audio_name

        output_folder = self.folder / job["id"]
        output_folder.mkdir(parents=True, exist_ok=True)
        preset = json.loads(json.dumps(job["preset"]))
        self.engine.interrupted.clear()
        self.engine.prepare_family_models(
            preset["version"], lambda value: self._progress(job, value)
        )
        for i in range(len(job["candidates"]), job["count"]):
            if self.closed or job["status"] == "cancelled":
                return
            last_error = None
            for attempt in range(3):
                if self.closed or job["status"] == "cancelled":
                    return
                params = dict(job["parameters"])
                seed = params["seed"]
                params["seed"] = random.randint(0, 2**32 - 1) if seed == -1 else (seed + i) % 2**32
                output = (
                    output_folder
                    / f"{safe_audio_name(job['text'], 32)}_{job['id'][:8]}_{i + 1:02}.wav"
                )
                self._progress(
                    job,
                    f"生成音频 {i + 1}/{job['count']}" + (f" · 重试 {attempt}" if attempt else ""),
                )
                started = time.monotonic()
                try:
                    self.engine.generate(preset, job["text"], job["language"], params, output)
                    if self.closed or job["status"] == "cancelled":
                        output.unlink(missing_ok=True)
                        return
                    audio, rate = sf.read(output, dtype="float32")
                    duration = len(audio) / rate
                    if (
                        len(audio) == 0
                        or not np.isfinite(audio).all()
                        or np.max(np.abs(audio)) < 1e-5
                    ):
                        raise CliError("生成结果为空或静音，请重试或更换参考音频。")
                    candidate = {
                        "id": uuid.uuid4().hex,
                        "path": str(output),
                        "duration": duration,
                        "seed": params["seed"],
                        "parameters": params,
                        "seconds": time.monotonic() - started,
                        "checked": True,
                    }
                    with self.lock:
                        if self.closed or job["status"] == "cancelled":
                            output.unlink(missing_ok=True)
                            return
                        job["candidates"].append(candidate)
                        self.persist()
                    break
                except Exception as error:
                    last_error = error
                    if (
                        attempt == 2
                        or "No module named" in str(error)
                        or "out of memory" in str(error)
                    ):
                        raise last_error

    def _candidate(self, data):
        job = next((j for j in self.jobs if j["id"] == data.get("job_id")), None)
        candidate = (
            next(
                (c for c in job.get("candidates", []) if c["id"] == data.get("candidate_id")), None
            )
            if job
            else None
        )
        if not candidate or not Path(candidate["path"]).is_file():
            raise CliError("生成音频已清理，请重新生成。")
        return job, candidate

    def _candidate_material(self, data):
        import soundfile as sf

        _, candidate = self._candidate(data)
        source = Path(candidate["path"]).resolve()
        if self.folder not in source.parents:
            raise CliError("生成音频路径无效。")
        info = sf.info(source)
        asset = {
            "id": candidate["id"],
            "source": "fh-project:/" + source.relative_to(self.project).as_posix(),
            "duration": info.duration,
            "sha256": digest(source),
        }
        edit = {
            "asset_id": asset["id"],
            "start": 0,
            "end": info.duration,
            "gain_db": 0,
            "audio_edits": [],
            **data.get("edit", {}),
            "keep_duration": False,
        }
        edit = {
            key: edit[key]
            for key in ("asset_id", "start", "end", "gain_db", "audio_edits", "keep_duration")
        }
        tools = Path(
            os.environ.get(
                "FH_RADIO_STUDIO_AUDIO_TOOLS_DIR", self.engine.home.parents[1] / "tools/audio"
            )
        )
        args = SimpleNamespace(
            ffmpeg=str(tools / "ffmpeg" / ("ffmpeg.exe" if os.name == "nt" else "ffmpeg"))
        )
        return source, asset, edit, args

    def candidate_audio(self, data):
        from .material_edit import material_wave
        from .voices import validate_edit

        _, asset, edit, args = self._candidate_material(data)
        validate_edit({"assets": [asset]}, edit)
        return material_wave(args, self.project, asset, edit, namespace="voices")

    def rendered_candidate(self, data):
        from .voices import render, validate_edit

        source, asset, edit, args = self._candidate_material(data)
        validate_edit({"assets": [asset]}, edit)
        if (
            edit["start"] == 0
            and edit["end"] == asset["duration"]
            and not edit["audio_edits"]
            and edit["gain_db"] == 0
        ):
            return source
        key = hashlib.sha256(
            json.dumps([asset["sha256"], edit], sort_keys=True, allow_nan=False).encode()
        ).hexdigest()
        output = source.parent / "edits" / f"{key}.wav"
        if not output.is_file():
            render(
                args,
                self.project,
                {"assets": [asset]},
                {"channels": 2, "frequency": 48000, "samples": 1},
                edit,
                output,
            )
        return output

    def accept(self, data):
        from .voices import import_assets, load_plan, plan_path

        with self.lock:
            job = next((j for j in self.jobs if j["id"] == data.get("job_id")), None)
            candidate = (
                next(
                    (c for c in job.get("candidates", []) if c["id"] == data.get("candidate_id")),
                    None,
                )
                if job
                else None
            )
            if not candidate:
                raise CliError("生成音频已移除，请重新生成。")
            target = job.get("target")
            with exclusive_file_lock(self.project / ".fh-radio-studio/voices.lock", timeout_sec=10):
                if target:
                    bank = load_plan(self.project)["banks"].get(target["bank_id"])
                    if not bank or bank["sha256"] != target["sha256"]:
                        raise CliError("原资源已变化，未应用生成结果。")
                existing_ids = {a["id"] for a in load_plan(self.project)["assets"]}
                result = import_assets(
                    self.project,
                    [str(self.rendered_candidate(data)) if data.get("edit") else candidate["path"]],
                    data.get("category", "生成语音"),
                    names=[job["text"][:80]],
                )
                asset_id = result["asset_ids"][0]
                plan = result["plan"]
                asset = next(a for a in plan["assets"] if a["id"] == asset_id)
                if asset_id not in existing_ids:
                    asset.update(
                        name=job["name"],
                        generation={
                            "job_id": job["id"],
                            "text": job["text"],
                            "preset_name": job["preset"]["name"],
                            "seed": candidate["seed"],
                            "revision": REVISION,
                            "parameters": candidate["parameters"],
                        },
                    )
                _write(plan_path(self.project), plan)
                # Return an ordinary edit, without saving replacement mappings.
                edit = {
                    "asset_id": asset_id,
                    "start": 0.0,
                    "end": asset["duration"],
                    "gain_db": 0.0,
                    "keep_duration": False,
                    "audio_edits": [],
                }
                previous_edit = job.get("adopted_edit")
                job["adopted_edit"] = edit
                job["accepted"] = candidate["id"]
                job["asset_id"] = asset_id
                self.persist()
                return {
                    "plan": plan,
                    "asset": asset,
                    "edit": edit,
                    "target": target,
                    "expected": target.get("expected") if target else None,
                    "previous_edit": previous_edit,
                }

    def action(self, action, data):
        if action == "status":
            return self.status()
        if action == "begin-app-session":
            session = str(data.get("id", ""))
            if not re.fullmatch(r"[a-zA-Z0-9_.-]{1,120}", session):
                raise CliError("应用会话标识无效。")
            marker = self.engine.home / "console-session.json"
            if _read(marker, {}).get("id") != session:
                log = self.engine.home / "engine.log"
                if log.exists():
                    log.write_text("", encoding="utf-8")
                self.engine.api._events.clear()
                _write(marker, {"id": session})
            return self.status()
        if action == "import-file":
            result = self.engine.import_file(data.get("kind"), data.get("path", ""))
            return {**self.status(), "imported_file": result}
        if action == "select-preset":
            if not any(p["id"] == data.get("id") for p in self.engine.settings()["presets"]):
                raise CliError("声音预设不存在。")
            _write(self.folder / "selection.json", {"preset_id": data["id"]})
            return self.status()
        if action == "delete-candidate":
            return self.delete_candidate(data)
        if action == "configure-downloads":
            if any(
                j.get("kind") == "install" and j["status"] in ("running", "queued")
                for j in self.jobs
            ):
                raise CliError("请先暂停安装，再切换下载源。")
            settings = self.engine.settings()
            settings["downloads"] = download_settings(data)
            _write(self.engine.config_path, settings)
            return self.status()
        if action == "check-installation":
            return self.status()
        if action == "pause-install":
            with self.lock:
                for job in self.jobs:
                    if job.get("kind") == "install" and job["status"] in ("running", "queued"):
                        job["status"] = "paused"
                self.persist()
            self.engine.stop()
            return self.status()
        if action == "open-install-directory":
            self.engine.home.mkdir(parents=True, exist_ok=True)
            return {"path": str(self.engine.home)}
        if action == "uninstall-engine":
            if any(j["status"] in ("running", "queued") for j in self.jobs):
                raise CliError("请先暂停安装或停止生成任务，再删除推理引擎。")
            self.engine.uninstall()
            return self.status()
        if action == "check-engine":
            if any(j["status"] in ("running", "queued") for j in self.jobs):
                return self.status()
            self.engine.api.cancelled.clear()
            if (
                self.engine.api.connection["mode"] == "managed"
                and not self.engine.status()["installed"]
            ):
                self.engine.api._set("unconfigured", "请先安装本地引擎，或连接已有同机 API。")
                return self.status()
            self.engine.api.check(passive=data.get("passive") is True)
            return self.status()
        if action == "configure-engine":
            if any(j["status"] in ("running", "queued") for j in self.jobs):
                raise CliError("请先停止或完成当前任务，再修改连接设置。")
            self.engine.api.configure(data)
            return self.status()
        if action == "clear-engine-logs":
            self.engine.api._events.clear()
            path = self.engine.home / "engine.log"
            if path.exists():
                path.write_text("", encoding="utf-8")
            return {"cleared": True}
        if action == "engine-logs":
            return self.engine.api.logs()
        if action == "validate-config":
            config = data.get("config") or next(iter(self.engine.settings()["presets"]), None)
            if not config:
                raise CliError("请先选择模型和参考音频。")
            self.engine.prepare_config(config)
            return {**self.status(), "configuration_valid": True}
        if action == "stop-engine":
            return self.action("cancel", {})
        if action in ("start-engine", "restart-engine"):
            if any(j["status"] in ("running", "queued") for j in self.jobs):
                raise CliError("已有任务正在处理，请稍候或先取消。")
            config = data.get("config") or next(iter(self.engine.settings()["presets"]), {})
            preset = self.engine.prepare_models(config)
            with self.lock:
                self.jobs.append(
                    {
                        "id": uuid.uuid4().hex,
                        "kind": action,
                        "preset": preset,
                        "status": "queued",
                        "created_at": time.time(),
                    }
                )
                self.persist()
            self.wake.set()
            return self.status()
        if action == "candidate-audio":
            return self.candidate_audio(data)
        if action == "acknowledge":
            with self.lock:
                preview_ids = data.get("preview_job_ids")
                if isinstance(preview_ids, list):
                    ids = {value for value in preview_ids if isinstance(value, str)}
                    for item in self.jobs:
                        if item["id"] in ids:
                            item["preview_dismissed"] = True
                    self.persist()
                    return self.status()
                job = next((j for j in self.jobs if j["id"] == data.get("job_id")), None)
                if job and job.get("accepted"):
                    job["consumed"] = True
                    self.persist()
            return self.status()
        if action == "export-audio":
            from .stingers import _run

            with self.lock:
                job = next((j for j in self.jobs if j["id"] == data.get("job_id")), None)
                candidate = (
                    next(
                        (
                            c
                            for c in job.get("candidates", [])
                            if c["id"] == data.get("candidate_id")
                        ),
                        None,
                    )
                    if job
                    else None
                )
            if not candidate or not Path(candidate["path"]).is_file():
                raise CliError("生成音频已清理，请从素材池导出已使用的音频。")
            target = Path(data["path"]).resolve()
            extension = target.suffix.lower()
            if extension not in (".wav", ".flac", ".mp3", ".ogg", ".aac"):
                raise CliError("请选择 WAV、FLAC、MP3、OGG 或 AAC。")
            if self.project in target.parents:
                raise CliError("导出请选择工程之外的位置；工程素材由应用统一管理。")
            source = self.rendered_candidate(data) if data.get("edit") else Path(candidate["path"])
            if extension == ".wav":
                shutil.copy2(source, target)
            else:
                tools = Path(
                    os.environ.get(
                        "FH_RADIO_STUDIO_AUDIO_TOOLS_DIR",
                        self.engine.home.parents[1] / "tools/audio",
                    )
                )
                ffmpeg = tools / "ffmpeg" / ("ffmpeg.exe" if os.name == "nt" else "ffmpeg")
                _run([str(ffmpeg), "-v", "error", "-y", "-i", str(source), str(target)])
            return {"path": str(target)}
        if action == "export-preset":
            preset = next(
                (p for p in self.engine.settings()["presets"] if p["id"] == data.get("id")), None
            )
            if not preset:
                raise CliError("声音预设不存在。")
            preset = json.loads(json.dumps(preset))
            for key in ("gpt_model", "sovits_model", "ref_audio_path"):
                preset[key] = str(self.engine.home / preset[key])
            preset["aux_ref_audio_paths"] = [
                str(self.engine.home / p) for p in preset["aux_ref_audio_paths"]
            ]
            return preset
        if action == "install":
            with self.lock:
                if any(j["status"] in ("queued", "running") for j in self.jobs):
                    raise CliError("请先暂停或完成当前任务。")
                paused_install = next(
                    (
                        j
                        for j in reversed(self.jobs)
                        if j.get("kind") == "install" and j["status"] == "paused"
                    ),
                    None,
                )
                if paused_install:
                    paused_install["status"] = "queued"
                    paused_install.pop("error", None)
                    self.persist()
                    self.wake.set()
                    return self.status()
                self.jobs.append(
                    {
                        "id": uuid.uuid4().hex,
                        "kind": action,
                        "status": "queued",
                        "created_at": time.time(),
                    }
                )
                self.persist()
            self.wake.set()
        elif action == "save-preset":
            self.engine.save_preset(data)
        elif action == "delete-preset":
            settings = self.engine.settings()
            settings["presets"] = [p for p in settings["presets"] if p["id"] != data.get("id")]
            _write(self.engine.config_path, settings)
        elif action == "submit":
            return self.submit(data)
        elif action == "accept":
            return self.accept(data)
        elif action in ("pause", "resume"):
            with self.lock:
                self.paused = action == "pause"
                if action == "resume":
                    for job in self.jobs:
                        if job["status"] == "paused":
                            job["status"] = "queued"
                self.persist()
            self.wake.set()
        elif action == "retry":
            with self.lock:
                for job in self.jobs:
                    if job["id"] in data.get("ids", []) and job["status"] in (
                        "failed",
                        "cancelled",
                    ):
                        job["status"] = "queued"
                        job.pop("error", None)
                self.persist()
            self.wake.set()
        elif action == "cancel":
            requested = set(data["ids"]) if isinstance(data.get("ids"), list) else None
            interrupt = requested is None
            with self.lock:
                for job in self.jobs:
                    if (requested is None or job["id"] in requested) and job["status"] in (
                        "running",
                        "queued",
                        "paused",
                    ):
                        interrupt = interrupt or job["status"] == "running"
                        job["status"] = "cancelled"
                self.persist()
            if interrupt:
                self.engine.stop()
        elif action == "unload":
            if any(j["status"] == "running" for j in self.jobs):
                raise CliError("请先取消或完成生成任务。")
            self.engine.stop()
        elif action == "clear-candidates":
            with self.lock:
                for job in self.jobs:
                    if job["status"] in ("running", "queued", "paused"):
                        continue
                    # Only temporary candidates; adopted sources and undo assets are untouched.
                    folder = (self.folder / job["id"]).resolve()
                    if (
                        re.fullmatch(r"[a-f0-9]{32}", job["id"])
                        and folder.parent == self.folder.resolve()
                        and folder.is_dir()
                    ):
                        shutil.rmtree(folder)
                    job["candidates"] = []
                self.persist()
        else:
            raise CliError("未知语音生成操作。")
        return self.status()

    def close(self):
        self.closed = True
        with self.lock:
            for job in self.jobs:
                if job["status"] in ("running", "queued"):
                    job["status"] = "paused"
            self.persist()
        self.engine.stop()
        self.wake.set()
        self.thread.join(timeout=5)
        log = self.engine.home / "engine.log"
        if log.exists():
            with contextlib.suppress(OSError):
                log.write_text("", encoding="utf-8")


def _cmd_speech_owned(args):
    project = Path(args.project_dir).resolve()
    if not (project / ".fh-radio-studio/project.json").is_file():
        raise CliError("请先打开工程。")
    home = (
        Path(args.engine_home)
        if args.engine_home
        else Path(
            os.environ.get("FH_RADIO_STUDIO_TOOLCHAIN_HOME", project / ".fh-radio-studio/toolchain")
        )
        / "engines/gpt-sovits"
    )
    workspace = GenerationWorkspace(project, Engine(home))
    try:
        if args.action == "serve":
            # A control thread receives cancellation while the inference thread works.
            for line in sys.stdin:
                message = {}
                try:
                    message = json.loads(line)
                    result = workspace.action(message["action"], message.get("input") or {})
                    response = {"id": message["id"], "result": result}
                except Exception as error:
                    response = {"id": message.get("id"), "error": str(error)}
                print(json.dumps(response, ensure_ascii=False, allow_nan=False), flush=True)
        else:
            data = json.load(sys.stdin) if args.input_json == "-" else {}
            result = workspace.action(args.action, data)
            if args.wait:
                while any(j["status"] in ("queued", "running") for j in workspace.status()["jobs"]):
                    time.sleep(0.3)
                result = workspace.status()
            print(json.dumps(result, ensure_ascii=False, allow_nan=False))
    finally:
        workspace.close()
    return 0


def cmd_speech(args):
    project = Path(args.project_dir).resolve()
    if not (project / ".fh-radio-studio/project.json").is_file():
        raise CliError("请先打开工程。")
    if args.action == "status":
        home = (
            Path(args.engine_home)
            if args.engine_home
            else Path(
                os.environ.get(
                    "FH_RADIO_STUDIO_TOOLCHAIN_HOME", project / ".fh-radio-studio/toolchain"
                )
            )
            / "engines/gpt-sovits"
        )
        print(
            json.dumps(
                {
                    "engine": Engine(home).status(),
                    "jobs": _read(project / "analysis/voices/generation/jobs.json", {"jobs": []})[
                        "jobs"
                    ],
                },
                ensure_ascii=False,
            )
        )
        return 0
    try:
        with exclusive_file_lock(project / ".fh-radio-studio/speech.lock"):
            return _cmd_speech_owned(args)
    except TimeoutError as error:
        raise CliError("此工程的语音生成已在运行，请在原窗口中操作。") from error
