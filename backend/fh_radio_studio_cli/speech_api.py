"""Loopback-only official GPT-SoVITS API client and owned service lifecycle."""

from __future__ import annotations

import contextlib
import http.client
import importlib.resources
import json
import os
import re
import socket
import subprocess
import threading
import time
import urllib.parse
from pathlib import Path

from .common import CliError
from .file_lock import exclusive_file_lock
from .stingers import _write


def connection_settings(value):
    value = value or {}
    mode = value.get("mode", "managed")
    port = value.get("port", 9880)
    timeout = value.get("timeout", 300)
    if mode not in ("managed", "existing") or type(port) is not int or not 1024 <= port <= 65535:
        raise CliError("请选择连接方式，端口范围为 1024–65535。")
    if type(timeout) not in (int, float) or not 10 <= timeout <= 1800:
        raise CliError("请求超时应为 10–1800 秒。")
    url = str(value.get("url", "http://127.0.0.1:9880")).strip().rstrip("/")
    parsed = urllib.parse.urlsplit(url)
    try:
        valid_port = parsed.port is None or 1 <= parsed.port <= 65535
    except ValueError:
        valid_port = False
    if (
        parsed.scheme not in ("http", "https")
        or parsed.hostname not in ("127.0.0.1", "localhost", "::1")
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or parsed.path not in ("", "/")
        or not valid_port
    ):
        raise CliError("本轮只支持同机 API，例如 http://127.0.0.1:9880。")
    return {
        "mode": mode,
        "port": port,
        "url": url,
        "timeout": timeout,
        "auto_start": value.get("auto_start", True) is True,
    }


class SpeechApi:
    def __init__(self, engine):
        self.engine = engine
        self.process = self.log = self.lease = None
        self.identity = None
        self.model_identity = None
        self.cancelled = threading.Event()
        self._connection = None
        self._socket = None
        self._checking = threading.Lock()
        self._validated_url = None
        self._events = []
        self._status = {"state": "stopped", "ready": False, "detail": "尚未连接", "checked_at": 0}

    @property
    def connection(self):
        return connection_settings(self.engine.settings().get("connection"))

    @property
    def url(self):
        config = self.connection
        return (
            f"http://127.0.0.1:{config['port']}" if config["mode"] == "managed" else config["url"]
        )

    def status(self):
        if (
            self.process is not None
            and self.process.poll() is not None
            and self._status["state"] != "error"
        ):
            self._set("error", "本地 API 进程已退出，请检查日志并重新启动。")
        return {
            **self._status,
            "url": self.url,
            "mode": self.connection["mode"],
            "owned": self.process is not None and self.process.poll() is None,
        }

    def _set(self, state, detail):
        self._status = {
            "state": state,
            "ready": state in ("ready", "generating"),
            "detail": detail,
            "checked_at": time.time(),
        }

    def _request(self, path, data=None, *, timeout=None):
        # Windows may keep a buffered HTTP read blocked after socket.shutdown.
        # Keep the queue cancellable independently of that read. The request
        # thread is daemon-only and never publishes audio or changes job state.
        done, result = threading.Event(), {}

        def request():
            try:
                result["value"] = self._request_sync(path, data, timeout=timeout)
            except Exception as error:
                result["error"] = error
            finally:
                done.set()

        threading.Thread(target=request, daemon=True).start()
        while not done.wait(0.05):
            if self.cancelled.is_set():
                raise CliError("请求已取消；外部 API 可能仍在完成原请求，其进程不会被关闭。")
        if self.cancelled.is_set():
            raise CliError("请求已取消。")
        if "error" in result:
            raise result["error"]
        return result["value"]

    def _request_sync(self, path, data=None, *, timeout=None):
        body = None if data is None else json.dumps(data, ensure_ascii=False).encode("utf-8")
        parsed = urllib.parse.urlsplit(self.url)
        cls = (
            http.client.HTTPSConnection if parsed.scheme == "https" else http.client.HTTPConnection
        )
        connection = cls(
            parsed.hostname, parsed.port, timeout=timeout or self.connection["timeout"]
        )
        self._connection = connection
        self._events.append(
            f"{time.strftime('%H:%M:%S')} {'POST' if body else 'GET'} {path.split('?')[0]}"
        )
        del self._events[:-100]
        try:
            connection.connect()
            self._socket = connection.sock
            if self.cancelled.is_set():
                raise CliError("请求已取消。")
            connection.request(
                "POST" if body is not None else "GET",
                path,
                body=body,
                headers={"Content-Type": "application/json"} if body is not None else {},
            )
            self._socket = connection.sock
            with connection.getresponse() as response:
                if response.status >= 400:
                    message = response.read(4096).decode("utf-8", errors="replace")
                    with contextlib.suppress(ValueError, TypeError):
                        parsed = json.loads(message)
                        message = str(parsed.get("message") or parsed.get("detail") or message)
                        if parsed.get("Exception"):
                            message += ": " + str(parsed["Exception"])
                    raise CliError(f"API 请求失败（{response.status}）：{message[:1000]}")
                result = bytearray()
                while True:
                    if self.cancelled.is_set():
                        raise CliError("生成已取消；已有 API 可能仍在完成其当前请求。")
                    block = response.read(1024 * 1024)
                    if not block:
                        return bytes(result)
                    result.extend(block)
        except (http.client.HTTPException, TimeoutError, OSError) as error:
            raise CliError(f"无法连接 {self.url}：{error}") from error
        finally:
            connection.close()
            if self._connection is connection:
                self._connection = None
                self._socket = None

    def check(self, *, passive=False):
        # A health probe must never replace the socket used by inference/cancel.
        if self._status["state"] == "generating" or not self._checking.acquire(blocking=False):
            return self.status()
        try:
            if self.connection["mode"] == "managed" and not (
                self.process is not None and self.process.poll() is None
            ):
                try:
                    with socket.create_connection(
                        ("127.0.0.1", self.connection["port"]), timeout=0.3
                    ):
                        pass
                except OSError:
                    self._set(
                        "stopped", "本地 API 尚未启动；导入 GPT 和 SoVITS 模型后点击启动服务。"
                    )
                    return self.status()
            # Poll reachability without fetching/logging the entire API schema.
            # First contact, manual tests and recovery still validate api_v2.
            if passive and self._validated_url == self.url and self._status["ready"]:
                parsed = urllib.parse.urlsplit(self.url)
                with socket.create_connection(
                    (parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80)),
                    timeout=2,
                ):
                    pass
                self._set("ready", "API 连接正常")
                return self.status()
            spec = json.loads(self._request("/openapi.json", timeout=2))
            paths = spec.get("paths", {})
            if "post" not in paths.get("/tts", {}) or any(
                p not in paths for p in ("/set_gpt_weights", "/set_sovits_weights")
            ):
                raise CliError("此地址不是兼容的 GPT-SoVITS api_v2 服务。")
            if self.connection["mode"] == "managed" and not (
                self.process is not None and self.process.poll() is None
            ):
                raise CliError(
                    "当前端口已有未由本应用启动的 API；请改用“连接已有同机 API”，或更换本地端口。"
                )
            self._set("ready", "API 连接正常")
            self._validated_url = self.url
        except (CliError, ValueError, OSError) as error:
            self._validated_url = None
            self._set("error", str(error))
        finally:
            self._checking.release()
        return self.status()

    def configure(self, data):
        config = connection_settings(data)
        if config == self.connection:
            return config
        if config != self.connection:
            self.stop()
        settings = self.engine.settings()
        settings["connection"] = config
        _write(self.engine.config_path, settings)
        self.cancelled.clear()
        self._set("stopped", "连接设置已保存，请检查连接。")
        return config

    def start(self, preset):
        from .speech_generation import _uv

        self.cancelled.clear()
        if self.connection["mode"] == "existing":
            result = self.check()
            if not result["ready"]:
                raise CliError(result["detail"])
            return result
        if self.process is not None and self.process.poll() is not None:
            self.stop()
            self.cancelled.clear()
        if self.process is not None and self.process.poll() is None:
            return self.status()
        if not self.engine.status()["api_dependencies_ready"]:
            raise CliError("本地 API 组件尚未安装，请点击“安装或修复”。")
        if not preset:
            raise CliError("请先导入 GPT 和 SoVITS 模型，再启动 API。参考音频仅在生成时需要。")
        with socket.socket() as probe:
            try:
                if os.name == "nt":
                    probe.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
                else:
                    probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                probe.bind(("127.0.0.1", self.connection["port"]))
            except OSError as error:
                raise CliError("端口已被占用：请更换端口，或切换为连接已有 API。")
        self.cancelled.clear()
        self.engine.interrupted.clear()
        self.lease = exclusive_file_lock(self.engine.home / "inference.lock")
        try:
            self.lease.__enter__()
        except TimeoutError as error:
            self.lease = None
            raise CliError("另一工程正在使用本地引擎，请先停止其生成。") from error
        params = preset["parameters"]
        config = {
            "custom": {
                "version": preset["version"],
                "device": params["device"],
                "is_half": params["is_half"] and params["device"] == "cuda",
                "t2s_weights_path": str(self.engine.home / preset["gpt_model"]),
                "vits_weights_path": str(self.engine.home / preset["sovits_model"]),
                "cnhuhbert_base_path": str(
                    self.engine.source / "GPT_SoVITS/pretrained_models/chinese-hubert-base"
                ),
                "bert_base_path": str(
                    self.engine.source
                    / "GPT_SoVITS/pretrained_models/chinese-roberta-wwm-ext-large"
                ),
            }
        }
        config_path = self.engine.home / "api-config.yaml"
        _write(config_path, config)  # JSON is valid YAML; no second serializer.
        self._set("starting", "正在加载模型并启动本地 API…")
        try:
            self.log = (self.engine.home / "engine.log").open("a", encoding="utf-8")
            self.process = subprocess.Popen(
                [
                    _uv(),
                    "run",
                    "--offline",
                    "--no-sync",
                    "--project",
                    str(self.engine.home / "runtime"),
                    "python",
                    "-u",
                    str(
                        importlib.resources.files(
                            "backend.fh_radio_studio_cli.tts_runtime"
                        ).joinpath("api_server.py")
                    ),
                    str(self.engine.home),
                    str(self.engine.source),
                    "-a",
                    "127.0.0.1",
                    "-p",
                    str(self.connection["port"]),
                    "-c",
                    str(config_path),
                ],
                cwd=self.engine.source,
                env=self.engine.environment_vars(),
                stdin=subprocess.DEVNULL,
                stdout=self.log,
                stderr=self.log,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            deadline = time.monotonic() + 180
            while time.monotonic() < deadline:
                if self.cancelled.is_set() or self.engine.interrupted.is_set():
                    raise CliError("启动已取消。")
                if self.process.poll() is not None:
                    raise CliError("本地 API 启动失败，请打开控制台输出查看原因。")
                if self.check()["ready"]:
                    self.identity = (preset["version"], params["device"], params["is_half"])
                    self.model_identity = (preset["gpt_model"], preset["sovits_model"])
                    return self.status()
                self._set("starting", "正在加载模型并启动本地 API…")
                time.sleep(0.25)
            raise CliError("API 启动超时，请检查模型路径与控制台输出。")
        except Exception as error:
            self.stop()
            self._set("error", str(error))
            raise

    def generate(self, preset, text, language, params, output):
        self.cancelled.clear()
        identity = (preset["version"], params["device"], params["is_half"])
        if self.connection["mode"] == "managed":
            if self.identity != identity and self.process is not None:
                self.stop()
                self.cancelled.clear()
            if self.process is None or self.process.poll() is not None:
                if not self.connection["auto_start"]:
                    raise CliError("API 尚未启动，请先打开引擎设置启动。")
                self.start({**preset, "parameters": params})
        elif not self.check()["ready"]:
            raise CliError(self.status()["detail"])
        model_identity = (preset["gpt_model"], preset["sovits_model"])
        try:
            if self.model_identity != model_identity or self.connection["mode"] == "existing":
                for endpoint, key in (
                    ("/set_gpt_weights", "gpt_model"),
                    ("/set_sovits_weights", "sovits_model"),
                ):
                    path = str(self.engine.home / preset[key])
                    self._request(endpoint + "?" + urllib.parse.urlencode({"weights_path": path}))
                self.model_identity = model_identity
            self._set("generating", "正在生成音频")
            request = {
                **params,
                "text": text,
                "text_lang": language,
                "ref_audio_path": str(self.engine.home / preset["ref_audio_path"]),
                "aux_ref_audio_paths": [
                    str(self.engine.home / p) for p in preset["aux_ref_audio_paths"]
                ],
                "prompt_text": "" if params["no_prompt"] else preset["prompt_text"],
                "prompt_lang": preset["prompt_lang"],
                "media_type": "wav",
                "streaming_mode": 0,
                "gpt_streaming": False,
            }
            audio = self._request("/tts", request)
            if self.cancelled.is_set():
                raise CliError("生成已取消。")
            temporary = Path(output).with_suffix(".partial.wav")
            try:
                temporary.write_bytes(audio)
                import soundfile as sf

                if sf.info(temporary).frames <= 0:
                    raise CliError("API 没有返回有效音频。")
                temporary.replace(output)
            finally:
                temporary.unlink(missing_ok=True)
            self._set("ready", "API 连接正常")
        except Exception as error:
            self.model_identity = None
            self._set("error", str(error))
            raise

    def stop(self):
        self.cancelled.set()
        connection = self._connection
        if connection is not None and self._socket is not None:
            with contextlib.suppress(OSError):
                self._socket.shutdown(socket.SHUT_RDWR)
        process, self.process = self.process, None
        if process is not None and process.poll() is None:
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
        if self.lease:
            self.lease.__exit__(None, None, None)
            self.lease = None
        self.identity = self.model_identity = None
        self._set(
            "stopped",
            (
                "本地 API 已停止"
                if self.connection["mode"] == "managed"
                else "已断开；外部服务保持运行"
            ),
        )

    def logs(self):
        path = self.engine.home / "engine.log"
        text = ""
        if path.is_file():
            with path.open("rb") as stream:
                stream.seek(max(0, path.stat().st_size - 65536))
                text = stream.read().decode("utf-8", errors="replace")
        if self.connection["mode"] == "existing":
            text = f"已有 API：{self.url}\n{self._status['detail']}\n外部进程的控制台由其启动程序管理。\n" + "\n".join(
                self._events
            )
        text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text).replace("\r", "\n")
        # Older running servers may still log successful health probes. Keep
        # failures and inference output visible; these 200 responses add no use.
        text = "\n".join(
            line
            for line in text.splitlines()
            if not (
                re.search(r'"GET /openapi\.json HTTP/[^\"]+" 200(?: OK)?\s*$', line)
                or re.search(r"^\d{2}:\d{2}:\d{2} GET /openapi\.json$", line)
            )
        )
        return {"text": text, "path": str(path)}
