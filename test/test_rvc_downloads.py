import importlib.resources
import os
import zipfile

import pytest

from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.rvc_downloads import (
    TORCH_MIRROR,
    rvc_download_settings,
    rvc_mirrored_runtime,
)
from backend.fh_radio_studio_cli.rvc_workspace import RvcEngine, RvcWorkspace
from backend.fh_radio_studio_cli.stingers import _write, digest


def test_mirror_preserves_cpu_cuda_versions_and_every_wheel_hash():
    import tomllib

    resources = importlib.resources.files("backend.fh_radio_studio_cli.rvc_environment")
    project = resources.joinpath("pyproject.toml").read_text(encoding="utf-8")
    lock = resources.joinpath("uv.lock").read_text(encoding="utf-8")
    mirrored_project, mirrored_lock = rvc_mirrored_runtime(
        project, lock, rvc_download_settings({"profile": "domestic"})
    )
    assert TORCH_MIRROR + "/cpu" in mirrored_project
    assert TORCH_MIRROR + "/cu128" in mirrored_project
    assert TORCH_MIRROR + "/cpu/torch-2.7.1%2Bcpu-cp310-cp310-win_amd64.whl" in mirrored_lock
    assert TORCH_MIRROR + "/cu128/torch-2.7.1%2Bcu128-cp310-cp310-win_amd64.whl" in mirrored_lock
    assert "https://pypi.tuna.tsinghua.edu.cn/packages/" in mirrored_lock
    assert "download-r2.pytorch.org" not in mirrored_lock
    original, changed = tomllib.loads(lock), tomllib.loads(mirrored_lock)
    signature = lambda data: [
        (p["name"], p["version"], [w["hash"] for w in p.get("wheels", [])]) for p in data["package"]
    ]
    assert signature(original) == signature(changed)
    tomllib.loads(mirrored_project)


@pytest.mark.parametrize(
    "address", ["http://bad.example", "https://user:pass@bad.example", "https://bad.example/b\nad"]
)
def test_custom_mirror_requires_safe_https(address):
    with pytest.raises(CliError):
        rvc_download_settings({"profile": "custom", "rvc_torch": address})


def test_source_settings_preserve_models_and_reject_changes_during_install(tmp_path):
    engine = RvcEngine(tmp_path / "engine")
    model = tmp_path / "voice.pth"
    model.write_bytes(b"placeholder")
    record = engine.catalog.import_file(model, "model")
    engine.catalog.select_model(record["id"])
    work = RvcWorkspace(tmp_path / "project", engine)
    try:
        result = work.action(
            "configure-downloads",
            {"profile": "domestic", "pypi": "https://mirrors.aliyun.com/pypi/simple"},
        )
        assert result["engine"]["downloads"]["pypi"] == "https://mirrors.aliyun.com/pypi/simple"
        assert result["engine"]["selection"]["model_id"] == record["id"]
        assert len(result["engine"]["files"]) == 1
        work.jobs.append({"kind": "install", "status": "running"})
        with pytest.raises(CliError, match="暂停安装"):
            work.action("configure-downloads", {"profile": "official"})
    finally:
        work.jobs.clear()
        work.close()


def test_installer_falls_back_to_official_without_unlocking_dependencies(tmp_path, monkeypatch):
    import backend.fh_radio_studio_cli.rvc_workspace as module

    engine = RvcEngine(tmp_path / "engine")
    engine.home.mkdir()
    archive = engine.home / "source.zip"
    with zipfile.ZipFile(archive, "w") as z:
        z.writestr("root/infer/modules/vc/modules.py", "# test")
    monkeypatch.setattr(module, "ARCHIVE_SHA", digest(archive))
    monkeypatch.setattr(module, "ASSETS", {})
    monkeypatch.setattr(module, "_uv", lambda: "uv")
    settings = engine.settings()
    settings["downloads"] = rvc_download_settings({"profile": "domestic"})
    _write(engine.catalog.path, settings)
    attempts = []

    class Process:
        def __init__(self, command, **kwargs):
            attempts.append(
                (
                    command,
                    (engine.home / "runtime/uv.lock").read_text(encoding="utf-8"),
                    kwargs["env"].copy(),
                )
            )

        def wait(self):
            return 1 if len(attempts) == 1 else 0

    monkeypatch.setattr(module.subprocess, "Popen", Process)
    progress = []
    engine.install(progress.append)
    assert len(attempts) == 2
    assert TORCH_MIRROR in attempts[0][1]
    assert "https://download.pytorch.org/whl/cpu" in attempts[1][1]
    assert all("--frozen" in a[0] and "torch-cpu" in a[0] for a in attempts)
    assert all("UV_OFFLINE" not in a[2] for a in attempts)
    assert any("回退官方源" in message for message in progress)


def test_device_switch_preserves_voice_and_flags_missing_cuda_dependencies(tmp_path):
    engine = RvcEngine(tmp_path / "engine")
    model = tmp_path / "voice.pth"
    model.write_bytes(b"placeholder")
    record = engine.catalog.import_file(model, "model")
    engine.catalog.select_model(record["id"])
    interpreter = engine.environment / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    interpreter.parent.mkdir(parents=True)
    interpreter.touch()
    work = RvcWorkspace(tmp_path / "project", engine)
    try:
        result = work.action("configure-runtime", {"device": "cuda:0"})
        assert result["engine"]["runtime"]["device"] == "cuda:0"
        assert not result["engine"]["components"][1]["ready"]
        assert result["engine"]["selection"]["model_id"] == record["id"]
        result = work.action("configure-runtime", {"device": "cpu"})
        assert result["engine"]["components"][1]["ready"]
    finally:
        work.close()
