import io
import re
import threading
import time
import urllib.error

import pytest

from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.speech_downloads import (
    download_settings,
    mirrored_runtime,
    model_url,
)
from backend.fh_radio_studio_cli.speech_generation import Engine, GenerationWorkspace


def wait_for(check):
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.01)
    assert check()


def test_mirror_preserves_locked_versions_and_hashes():
    from importlib.resources import files

    resources = files("backend.fh_radio_studio_cli.tts_runtime")
    project = resources.joinpath("pyproject.toml").read_text(encoding="utf-8")
    lock = resources.joinpath("uv.lock").read_text(encoding="utf-8")
    changed_project, changed_lock = mirrored_runtime(
        project, lock, download_settings({"profile": "domestic"})
    )
    assert "mirror.sjtu.edu.cn/pytorch-wheels/cu126" in changed_project
    assert "pypi.tuna.tsinghua.edu.cn" in changed_lock
    assert re.findall(r"sha256:[a-f0-9]+", changed_lock) == re.findall(r"sha256:[a-f0-9]+", lock)
    assert model_url(
        "https://huggingface.co/a/b/resolve/main/c", download_settings({"profile": "domestic"})
    ).startswith("https://hf-mirror.com/")


@pytest.mark.parametrize(
    "value", ["http://wrong", "https://bad/\nnext", 'https://bad/"', "https://user:secret@wrong/"]
)
def test_invalid_custom_mirrors_rejected(value):
    with pytest.raises(CliError):
        download_settings({"profile": "custom", "hf": value})


def test_download_resumes_and_reports_real_bytes(tmp_path, monkeypatch):
    engine = Engine(tmp_path / "engine")
    target = tmp_path / "model.bin.part"
    target.write_bytes(b"abc")
    progress = []
    engine._download_progress = progress.append

    class Response(io.BytesIO):
        status = 206
        headers = {"Content-Range": "bytes 3-5/6", "Content-Length": "3"}

    def open_url(request, **kwargs):
        assert request.get_header("Range") == "bytes=3-"
        return Response(b"def")

    monkeypatch.setattr("urllib.request.urlopen", open_url)
    engine.download("https://huggingface.co/repo/model.bin", target)
    assert target.read_bytes() == b"abcdef"
    assert progress[-1]["download"]["received"] == 6
    assert progress[-1]["download"]["fraction"] == 1


def test_components_do_not_claim_complete_from_marker_only(tmp_path):
    engine = Engine(tmp_path)
    (tmp_path / "installation.json").write_text("{}", encoding="utf-8")
    assert engine.status()["installed"] is False
    assert any(not c["ready"] for c in engine.components())


def test_optional_roberta_tokenizer_config_is_not_requested(tmp_path, monkeypatch):
    engine = Engine(tmp_path)
    dictionary = tmp_path / "open_jtalk_dic_utf_8-1.11/sys.dic"
    dictionary.parent.mkdir(parents=True)
    dictionary.write_bytes(b"dict")
    for folder in (
        "corpora/cmudict",
        "taggers/averaged_perceptron_tagger",
        "taggers/averaged_perceptron_tagger_eng",
    ):
        (tmp_path / "nltk_data" / folder).mkdir(parents=True)
    requested = []

    def download(url, target):
        requested.append(url)
        target.write_bytes(b"verified mock")

    monkeypatch.setattr(engine, "download", download)
    engine.prepare_base_models(lambda _: None)
    assert not any("tokenizer_config.json" in url for url in requested)
    assert any("tokenizer.json" in url for url in requested)
    assert len(requested) == 8


def test_pause_restore_resume_install_and_application_log_cleanup(tmp_path):
    class PausableEngine(Engine):
        def __init__(self, home):
            super().__init__(home)
            self.entered = threading.Event()
            self.attempts = 0

        def install(self, progress):
            self.interrupted.clear()
            self.attempts += 1
            self.entered.set()
            if self.attempts == 1:
                assert self.interrupted.wait(3)
                raise CliError("paused")
            progress("components ready")

    engine = PausableEngine(tmp_path / "engine")
    engine.home.mkdir()
    (engine.home / "engine.log").write_text("retained log", encoding="utf-8")
    workspace = GenerationWorkspace(tmp_path / "project", engine)
    workspace.action("install", {})
    assert engine.entered.wait(2)
    install_id = workspace.jobs[0]["id"]
    workspace.action("pause-install", {})
    assert workspace.jobs[0]["status"] == "paused"
    assert (engine.home / "engine.log").read_text(encoding="utf-8") == "retained log"
    workspace.close()
    assert (engine.home / "engine.log").read_text(encoding="utf-8") == ""
    restored = GenerationWorkspace(tmp_path / "project", engine)
    try:
        assert restored.jobs[0]["status"] == "paused"
        restored.action("install", {})
        wait_for(lambda: restored.jobs[0]["status"] == "ready")
        assert len(restored.jobs) == 1
        assert restored.jobs[0]["id"] == install_id
        assert engine.attempts == 2
    finally:
        restored.close()
