import socket
from pathlib import Path
from test.test_speech_installer_revision import wait_for

import numpy as np
import soundfile as sf

from backend.fh_radio_studio_cli.speech_generation import Engine, GenerationWorkspace


def test_console_retained_within_application_and_reset_next_application(tmp_path):
    engine = Engine(tmp_path / "engine")
    engine.home.mkdir()
    log = engine.home / "engine.log"
    log.write_text("old app", encoding="utf-8")
    work = GenerationWorkspace(tmp_path / "project", engine)
    try:
        work.action("begin-app-session", {"id": "app-one"})
        assert log.read_text(encoding="utf-8") == ""
        log.write_text("current app", encoding="utf-8")
        work.action("begin-app-session", {"id": "app-one"})
        assert log.read_text(encoding="utf-8") == "current app"
        work.action("begin-app-session", {"id": "app-two"})
        assert log.read_text(encoding="utf-8") == ""
    finally:
        work.close()


def test_imports_models_and_reference_immediately_without_a_preset(tmp_path):
    engine = Engine(tmp_path / "engine")
    model = tmp_path / "Original.ckpt"
    model.write_bytes(b"model")
    imported = engine.import_file("gpt_model", str(model))
    model.unlink()
    assert (engine.home / imported["path"]).read_bytes() == b"model"
    assert imported["filename"] == "Original.ckpt"
    assert (engine.home / imported["path"]).name.startswith("Original_")
    assert engine.settings()["presets"] == []
    ref = tmp_path / "Original reference.wav"
    sf.write(ref, np.zeros(24000 * 4), 24000)
    imported = engine.import_file("ref_audio_path", str(ref))
    ref.unlink()
    assert sf.info(engine.home / imported["path"]).duration == 4
    assert (engine.home / imported["path"]).name.startswith("Original reference_")
    assert engine.settings()["imports"][-1]["filename"] == "Original reference.wav"


def test_start_service_only_validates_models_not_reference_audio(tmp_path, monkeypatch):
    engine = Engine(tmp_path / "engine")
    gpt = tmp_path / "a.ckpt"
    gpt.write_bytes(b"gpt")
    sovits = tmp_path / "a.pth"
    sovits.write_bytes(b"sovits")
    captured = []
    monkeypatch.setattr(engine.api, "start", lambda config: captured.append(config))
    monkeypatch.setattr(engine, "prepare_family_models", lambda *args: None)
    monkeypatch.setattr(
        engine,
        "prepare_config",
        lambda *args: (_ for _ in ()).throw(
            AssertionError("Reference must not be validated during service startup")
        ),
    )
    work = GenerationWorkspace(tmp_path / "project", engine)
    try:
        work.action(
            "start-engine",
            {
                "config": {
                    "gpt_model": str(gpt),
                    "sovits_model": str(sovits),
                    "ref_audio_path": "",
                    "version": "v2ProPlus",
                }
            },
        )
        wait_for(lambda: work.jobs[-1]["status"] == "ready")
        assert len(captured) == 1 and "ref_audio_path" not in captured[0]
    finally:
        work.close()


def test_managed_unstarted_api_reports_stopped_instead_of_error(tmp_path, monkeypatch):
    engine = Engine(tmp_path / "engine")
    engine.api._set("error", "previous connection timeout")

    def unavailable(*args, **kwargs):
        raise ConnectionRefusedError()

    monkeypatch.setattr(socket, "create_connection", unavailable)
    assert engine.api.check()["state"] == "stopped"
