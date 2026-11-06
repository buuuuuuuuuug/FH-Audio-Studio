from backend.fh_radio_studio_cli import speech_generation as speech
from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.speech_downloads import download_candidates, download_settings


def test_dictionary_fallback_restarts_partial_archive(tmp_path, monkeypatch):
    engine = speech.Engine(tmp_path / "gpt-sovits")
    calls = []

    def download(address, target, *, restart=False):
        calls.append((address, restart))
        if len(calls) == 1:
            raise CliError("certificate failure")

    monkeypatch.setattr(engine, "_download_once", download)
    engine.download(
        "https://github.com/r9y9/open_jtalk/releases/download/v1.11.1/open_jtalk_dic_utf_8-1.11.tar.gz",
        tmp_path / "dict.tar.gz",
    )
    assert len(calls) == 2
    assert calls[0][1] is False and calls[1][1] is True
    assert "sourceforge.net" in calls[1][0]


def test_model_mirror_has_official_fallback():
    url = "https://huggingface.co/lj1995/GPT-SoVITS/resolve/main/file.bin"
    assert download_candidates(url, download_settings({"profile": "domestic"})) == [
        url.replace("huggingface.co", "hf-mirror.com"),
        url,
    ]


def test_install_can_download_when_portable_parent_is_offline(tmp_path, monkeypatch):
    engine = speech.Engine(tmp_path / "engine")
    source = engine.source / "GPT_SoVITS/TTS_infer_pack/TTS.py"
    source.parent.mkdir(parents=True)
    source.write_text("", encoding="utf-8")
    monkeypatch.setenv("UV_OFFLINE", "true")
    monkeypatch.setattr(engine.api, "stop", lambda: None)
    monkeypatch.setattr(engine, "prepare_base_models", lambda progress: None)
    monkeypatch.setattr(engine, "components", lambda: [{"name": "mock", "ready": True}])
    monkeypatch.setattr(speech, "_uv", lambda: "bundled-uv")
    captured = {}

    class Process:
        def __init__(self, command, **kwargs):
            captured.update(kwargs["env"])

        def wait(self):
            return 0

    monkeypatch.setattr(speech.subprocess, "Popen", Process)
    engine.install(lambda message: None)
    assert "UV_OFFLINE" not in captured
    assert "UV_NO_PROGRESS" not in captured
    assert "HF_HUB_OFFLINE" not in captured
    assert captured["UV_PROJECT_ENVIRONMENT"] == str(engine.environment)
    assert (engine.home / "installation.json").is_file()
    assert engine.environment_vars()["UV_OFFLINE"] == "true"
