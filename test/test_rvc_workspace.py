"""Exercise the shared queue/adoption workflow without inference downloads."""

import time
from pathlib import Path
from test.test_voices import resource

import numpy as np
import pytest
import soundfile as sf

from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.rvc_workspace import RvcEngine, RvcWorkspace
from backend.fh_radio_studio_cli.stingers import local_file
from backend.fh_radio_studio_cli.voices import load_plan, prepare


class FakeEngine(RvcEngine):
    def request(self, request, progress=None):
        source, rate = sf.read(request["input"])
        sf.write(request["output"], source * 0.5, rate)
        return {"path": request["output"], "duration": len(source) / rate, "sample_rate": rate}


def wait(work):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        jobs = work.status()["jobs"]
        if all(j["status"] not in ("running", "queued") for j in jobs):
            return jobs
        time.sleep(0.01)
    pytest.fail("queue did not finish")


@pytest.fixture
def work(tmp_path):
    engine = FakeEngine(tmp_path / "engine")
    model = tmp_path / "model.pth"
    model.write_bytes(b"placeholder-never-deserialized")
    record = engine.catalog.import_file(model, "model")
    engine.catalog.select_model(record["id"])
    workspace = RvcWorkspace(tmp_path / "project", engine)
    yield workspace
    workspace.close()


def audio(path):
    sf.write(path, np.sin(np.arange(1600) * 0.1).astype("float32") * 0.1, 16000)
    return path


def test_conversion_adoption_edit_delete_and_original_preservation(work, tmp_path):
    source = audio(tmp_path / "原音.wav")
    before = source.read_bytes()
    work.action("import-input", {"paths": [str(source)]})
    inputs = work.status()["inputs"]
    work.submit({"entries": inputs})
    job = wait(work)[0]
    assert job["status"] == "ready", job
    candidate = job["candidates"][0]
    request = {"job_id": job["id"], "candidate_id": candidate["id"]}
    rendered = work.action("candidate-audio", request)
    assert Path(rendered["path"]).is_file()
    adopted = work.action("accept", request)
    assert adopted["asset"]["generation"]["engine"] == "RVC"
    assert adopted["asset"]["category"] == "音色转换"
    owned = local_file(work.project, adopted["asset"]["source"])
    assert owned.exists()
    work.action("delete-candidate", request)
    assert not owned.exists()
    assert not Path(candidate["path"]).exists()
    work.action("clear-inputs", {})
    assert work.status()["inputs"] == []
    assert not Path(inputs[0]["path"]).exists()
    assert source.read_bytes() == before


def test_paused_queue_model_parameters_and_retry(work, tmp_path):
    source = audio(tmp_path / "speech.wav")
    work.engine.catalog.save_parameters({"pitch": 12})
    work.submit(
        {"entries": [{"path": str(source), "name": "one"}, {"path": str(source), "name": "two"}]}
    )
    jobs = wait(work)
    assert len(jobs) == 2 and all(j["status"] == "ready" for j in jobs)
    assert all(j["snapshot"]["parameters"]["pitch"] == 12 for j in jobs)
    work.action("pause", {})
    assert work.status()["paused"]
    work.action("resume", {})
    assert not work.status()["paused"]
    with pytest.raises(CliError):
        work.action("configure-runtime", {"device": "arbitrary"})


def test_target_snapshot_and_expected_edit_preserved(resource, monkeypatch):
    project, game, bank_source = resource
    bank = prepare(project, game, bank_source)["bank"]
    engine = FakeEngine(project / "engine")
    model = project / "voice.pth"
    model.write_bytes(b"placeholder")
    rec = engine.catalog.import_file(model, "model")
    engine.catalog.select_model(rec["id"])
    source = audio(project / "original.wav")
    seen = []

    def original(args, p, bank_id, index, language):
        assert args.game_dir
        seen.append((bank_id, index, language))
        return {"path": str(source)}

    monkeypatch.setattr("backend.fh_radio_studio_cli.voices.original", original)
    work = RvcWorkspace(project, engine)
    target = {
        "bank_id": bank["id"],
        "sha256": bank["sha256"],
        "index": 1,
        "expected": {"asset_id": "previous"},
    }
    try:
        work.submit(
            {
                "origin": "replacement",
                "entries": [{"name": "original", "voice_language": "JP", "target": target}],
            }
        )
        job = wait(work)[0]
        result = work.accept({"job_id": job["id"], "candidate_id": job["candidates"][0]["id"]})
        assert seen == [(bank["id"], 1, "JP")]
        assert result["target"] == target
        assert result["expected"] == {"asset_id": "previous"}
        assert not load_plan(project)["banks"][bank["id"]]["replacements"]
    finally:
        work.close()
