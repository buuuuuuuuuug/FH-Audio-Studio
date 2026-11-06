"""Official HTTP protocol, same-machine boundary and cancellation ownership."""

import io
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

import numpy as np
import pytest
import soundfile as sf

from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.speech_api import connection_settings
from backend.fh_radio_studio_cli.speech_generation import Engine, parameters
from backend.fh_radio_studio_cli.voices import import_assets, safe_audio_name


@pytest.fixture
def api(tmp_path):
    events, entered, release = [], threading.Event(), threading.Event()
    buffer = io.BytesIO()
    sf.write(buffer, np.ones(2400) * 0.1, 24000, format="WAV")

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            events.append(self.path)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(
                json.dumps(
                    {
                        "paths": {
                            "/tts": {"post": {}},
                            "/set_gpt_weights": {"get": {}},
                            "/set_sovits_weights": {"get": {}},
                        }
                    }
                ).encode()
            )

        def do_POST(self):
            events.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
            entered.set()
            release.wait(3)
            self.send_response(200)
            self.end_headers()
            try:
                self.wfile.write(
                    buffer.getvalue() if not getattr(self.server, "invalid", False) else b"bad wav"
                )
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    engine = Engine(tmp_path / "engine")
    engine.api.configure({"mode": "existing", "url": f"http://127.0.0.1:{server.server_port}"})
    preset = {
        "version": "v2ProPlus",
        "gpt_model": "models/voice.ckpt",
        "sovits_model": "models/voice.pth",
        "ref_audio_path": "references/main.wav",
        "aux_ref_audio_paths": ["references/aux.wav"],
        "prompt_text": "reference",
        "prompt_lang": "all_ja",
    }
    yield engine, preset, events, entered, release, server
    engine.stop()
    release.set()
    server.shutdown()
    server.server_close()
    thread.join(3)


@pytest.mark.parametrize(
    "value",
    [
        {"url": "http://example.com:9880"},
        {"url": "file:///tmp/audio"},
        {"url": "http://127.0.0.1:9880/path"},
        {"url": "http://user@localhost:9880"},
        {"url": "http://localhost:bad"},
        {"port": True},
        {"port": 1000},
        {"timeout": float("nan")},
        {"timeout": 0},
        {"mode": "unknown"},
    ],
)
def test_same_machine_configuration_rejects_invalid_inputs(value):
    with pytest.raises(CliError):
        connection_settings(value)


def test_health_does_not_switch_models_or_generate(api):
    engine, _, events, *_ = api
    assert engine.api.check()["ready"]
    assert events == ["/openapi.json"]
    assert not engine.api.status()["owned"]


def test_official_request_switches_models_and_uses_only_preset_reference(api, tmp_path):
    engine, preset, events, _, release, _ = api
    release.set()
    output = tmp_path / "语音.wav"
    engine.generate(preset, "new text", "all_ja", parameters({}), output)
    assert sf.info(output).frames == 2400
    assert any(str(p).startswith("/set_gpt_weights?weights_path=") for p in events)
    assert any(str(p).startswith("/set_sovits_weights?weights_path=") for p in events)
    request = events[-1]
    assert request["text"] == "new text"
    assert request["prompt_text"] == preset["prompt_text"]
    assert request["ref_audio_path"] == str(engine.home / preset["ref_audio_path"])
    assert request["streaming_mode"] == 0
    assert request["aux_ref_audio_paths"] == [str(engine.home / preset["aux_ref_audio_paths"][0])]
    assert "original_reference" not in request


def test_passive_health_checks_reuse_schema_and_keep_error_logs(api):
    engine, _, events, _, _, _ = api
    assert engine.api.check()["ready"]
    for _ in range(4):
        assert engine.api.check(passive=True)["ready"]
    assert events == ["/openapi.json"]
    assert engine.api.check()["ready"]  # Explicit connection test revalidates.
    assert events == ["/openapi.json", "/openapi.json"]
    engine.api.configure({"mode": "managed"})
    engine.home.mkdir(parents=True, exist_ok=True)
    (engine.home / "engine.log").write_text(
        'INFO: 127.0.0.1:13554 - "GET /openapi.json HTTP/1.1" 200 OK\n'
        'INFO: 127.0.0.1:13554 - "GET /openapi.json HTTP/1.1" 500 Internal Server Error\n'
        "生成失败：模型加载错误\n",
        encoding="utf-8",
    )
    log = engine.api.logs()["text"]
    assert "200 OK" not in log
    assert "500 Internal Server Error" in log
    assert "模型加载错误" in log


def test_cancelling_external_request_keeps_server_alive_and_cleans_partial(api, tmp_path):
    engine, preset, events, entered, release, _ = api
    failures = []

    def generate():
        try:
            engine.generate(preset, "text", "all_ja", parameters({}), tmp_path / "out.wav")
        except Exception as error:
            failures.append(error)

    thread = threading.Thread(target=generate)
    thread.start()
    assert entered.wait(2)
    before = len(events)
    assert engine.api.check()["state"] == "generating"
    assert len(events) == before  # Health must not steal the pending request socket.
    engine.stop()
    thread.join(2)
    assert not thread.is_alive()
    assert failures
    assert not list(tmp_path.glob("*.wav"))
    release.set()
    engine.api.cancelled.clear()
    assert engine.api.check()["ready"]  # External process was not terminated.


def test_invalid_audio_never_becomes_output(api, tmp_path):
    engine, preset, _, _, release, server = api
    server.invalid = True
    release.set()
    with pytest.raises(Exception):
        engine.generate(preset, "text", "en", parameters({}), tmp_path / "bad.wav")
    assert not list(tmp_path.glob("*.wav"))
    assert engine.api.status()["state"] == "error"


def test_managed_port_occupied_is_reported_without_killing_server(api):
    engine, preset, _, _, _, server = api
    # Dependency check is local to the managed mode; simulate installed modules.
    for name in ("fastapi", "uvicorn", "python_multipart"):
        path = engine.environment / "Lib/site-packages" / name / "__init__.py"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch()
    engine.api.configure({"mode": "managed", "port": server.server_port})
    with pytest.raises(CliError, match="端口已被占用"):
        engine.api.start(preset)
    engine.api.configure({"mode": "existing", "url": f"http://127.0.0.1:{server.server_port}"})
    assert engine.api.check()["ready"]


def test_readable_material_names_preserve_ids_and_old_hash_sources(tmp_path):
    project = tmp_path / "project"
    project.mkdir()
    source = tmp_path / "source.wav"
    sf.write(source, np.ones(2400) * 0.1, 24000)
    first = import_assets(project, [source], "生成语音", names=["你好：下一首 / 歌曲？"])
    asset = first["plan"]["assets"][0]
    assert asset["name"] == "你好：下一首 / 歌曲？"
    assert "你好" in unquote(asset["source"]) and len(asset["id"]) == 64
    again = import_assets(project, [source], "生成语音", names=["another"])
    assert len(again["plan"]["assets"]) == 1
    assert again["plan"]["assets"][0]["id"] == asset["id"]
    assert safe_audio_name("CON") != "CON"
    assert "/" not in safe_audio_name("a/b:c")


def test_paused_generation_does_not_block_engine_control(tmp_path, monkeypatch):
    from test.test_speech_generation import TestEngine, wait

    from backend.fh_radio_studio_cli.speech_generation import GenerationWorkspace

    engine = TestEngine(tmp_path / "engine")
    work = GenerationWorkspace(tmp_path / "project", engine)
    try:
        work.action("pause", {})
        monkeypatch.setattr(engine, "prepare_family_models", lambda *a: None)
        monkeypatch.setattr(engine, "prepare_models", lambda value: value)
        monkeypatch.setattr(engine.api, "start", lambda *a: None)
        work.action("start-engine", {})
        assert wait(work)[-1]["status"] == "ready"
        assert work.paused and not engine.calls
    finally:
        work.close()


def test_managed_health_does_not_claim_an_external_service(api):
    engine, _, events, *_ = api
    engine.api.configure(
        {"mode": "managed", "port": int(engine.api.connection["url"].rsplit(":", 1)[-1])}
    )
    status = engine.api.check()
    assert not status["ready"] and not status["owned"]
    assert "连接已有同机 API" in status["detail"]
    assert events == ["/openapi.json"]


def test_managed_service_stdin_is_isolated(tmp_path, monkeypatch):
    import subprocess
    from unittest.mock import Mock

    engine = Engine(tmp_path / "engine")
    for name in ("fastapi", "uvicorn", "python_multipart"):
        path = engine.environment / "Lib/site-packages" / name / "__init__.py"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch()
    preset = {
        "version": "v2",
        "parameters": parameters({}),
        "gpt_model": "voice.ckpt",
        "sovits_model": "voice.pth",
    }
    process = Mock()
    process.poll.return_value = None
    import socket

    with socket.socket() as port:
        port.bind(("127.0.0.1", 0))
        engine.api.configure({"mode": "managed", "port": port.getsockname()[1]})
    launch = Mock(return_value=process)
    monkeypatch.setattr(subprocess, "Popen", launch)
    monkeypatch.setattr(engine.api, "check", lambda: {"ready": True})
    monkeypatch.setattr(engine.api, "stop", lambda: None)
    try:
        engine.api.start(preset)
        assert launch.call_args.kwargs["stdin"] == subprocess.DEVNULL
    finally:
        if engine.api.log:
            engine.api.log.close()
        if engine.api.lease:
            engine.api.lease.__exit__(None, None, None)
