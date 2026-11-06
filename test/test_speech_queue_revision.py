import json
from test.test_speech_installer_revision import wait_for

from backend.fh_radio_studio_cli.speech_generation import Engine, GenerationWorkspace


def test_new_generation_runs_after_restoring_paused_work(tmp_path, monkeypatch):
    project = tmp_path / "project"
    folder = project / "analysis/voices/generation"
    folder.mkdir(parents=True)
    (folder / "jobs.json").write_text(
        json.dumps(
            {
                "jobs": [
                    {"id": "previous", "status": "paused", "text": "old", "candidates": []},
                ]
            }
        ),
        encoding="utf-8",
    )
    engine = Engine(tmp_path / "engine")
    preset = {"id": "preset", "version": "v2ProPlus", "text_lang": "all_ja", "parameters": {}}
    monkeypatch.setattr(engine, "prepare_config", lambda _: preset)
    generated = []
    monkeypatch.setattr(
        GenerationWorkspace, "_generate", lambda self, job: generated.append(job["text"])
    )
    workspace = GenerationWorkspace(project, engine)
    try:
        assert workspace.paused
        workspace.submit({"config": {}, "entries": [{"text": "new"}]})
        wait_for(lambda: workspace.jobs[-1]["status"] == "ready")
        assert generated == ["new"]
        assert workspace.jobs[0]["status"] == "paused"
        assert not workspace.status()["paused"]
    finally:
        workspace.close()


def test_cancelling_a_batch_keeps_other_paused_jobs(tmp_path, monkeypatch):
    engine = Engine(tmp_path / "engine")
    workspace = GenerationWorkspace(tmp_path / "project", engine)
    stops = []
    monkeypatch.setattr(engine, "stop", lambda: stops.append(True))
    try:
        workspace.jobs = [
            {"id": "old", "status": "paused"},
            {"id": "batch", "status": "paused"},
        ]
        workspace.action("cancel", {"ids": ["batch"]})
        assert workspace.jobs[0]["status"] == "paused"
        assert workspace.jobs[1]["status"] == "cancelled"
        assert not stops
    finally:
        workspace.close()
