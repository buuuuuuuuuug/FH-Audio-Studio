import io

import pytest

from backend.fh_radio_studio_cli.speech_generation import INSTALL_STEPS, Engine


def test_uninstall_removes_runtime_but_keeps_imported_voice_files(tmp_path):
    home = tmp_path / "gpt-sovits"
    engine = Engine(home)
    owned = [engine.source, home / "environment", home / "runtime", home / "nltk_data"]
    for folder in owned:
        folder.mkdir(parents=True)
        (folder / "test.bin").write_bytes(b"runtime")
    for folder in ["models", "references"]:
        (home / folder).mkdir()
        (home / folder / "keep.bin").write_bytes(b"user")
    (home / "settings.json").write_text('{"presets":[]}')
    (home / "installation.json").write_text("{}")
    engine.uninstall()
    assert all(not folder.exists() for folder in owned)
    assert not (home / "installation.json").exists()
    assert (home / "settings.json").is_file()
    assert (home / "models/keep.bin").read_bytes() == b"user"
    assert (home / "references/keep.bin").read_bytes() == b"user"


def test_resume_speed_excludes_cached_bytes_and_updates_overall(tmp_path, monkeypatch):
    engine = Engine(tmp_path / "engine")
    target = tmp_path / "model.part"
    target.write_bytes(b"abc")
    progress = []
    engine._download_progress = progress.append
    engine._install_stage = {"completed": 5, "total": INSTALL_STEPS, "stage": "base"}

    class Response(io.BytesIO):
        status = 206
        headers = {"Content-Range": "bytes 3-5/6", "Content-Length": "3"}

    monkeypatch.setattr("urllib.request.urlopen", lambda *args, **kw: Response(b"def"))
    ticks = iter([10.0, 12.0, 14.0])
    monkeypatch.setattr(
        "backend.fh_radio_studio_cli.speech_generation.time.monotonic", lambda: next(ticks)
    )
    engine.download("https://huggingface.co/repo/model", target)
    assert progress[-1]["download"]["bytes_per_second"] == 1.5
    assert progress[-1]["download"]["received"] == 6
    assert progress[-1]["installation"]["fraction"] == pytest.approx(6 / INSTALL_STEPS)
    assert target.read_bytes() == b"abcdef"
    assert "MiB/s" in (engine.home / "engine.log").read_text(encoding="utf-8")


def test_base_model_progress_counts_cached_files_and_language_data(tmp_path, monkeypatch):
    engine = Engine(tmp_path / "engine")
    engine._install_stage = {"completed": 2, "total": INSTALL_STEPS}
    dictionary = engine.home / "open_jtalk_dic_utf_8-1.11/sys.dic"
    dictionary.parent.mkdir(parents=True)
    dictionary.write_bytes(b"dict")
    for folder in (
        "corpora/cmudict",
        "taggers/averaged_perceptron_tagger",
        "taggers/averaged_perceptron_tagger_eng",
    ):
        (engine.home / "nltk_data" / folder).mkdir(parents=True)
    requested = []

    def download(url, target):
        requested.append(url)
        target.write_bytes(b"model")

    monkeypatch.setattr(engine, "download", download)
    values = []
    engine.prepare_base_models(values.append)
    assert values[-1]["installation"]["completed"] == INSTALL_STEPS - 1
    assert max(v["installation"]["fraction"] for v in values) < 1
    assert set(range(2, INSTALL_STEPS)) <= {v["installation"]["completed"] for v in values}
    values.clear()
    engine.prepare_base_models(values.append)
    assert len(requested) == 8
    assert "https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.bin" in requested
    assert not any("/GPT-SoVITS/resolve/main/fast_langdetect/" in url for url in requested)
    assert values[-1]["installation"]["completed"] == INSTALL_STEPS - 1
    engine._stage(values.append, INSTALL_STEPS, "verified")
    assert values[-1]["installation"]["fraction"] == 1
