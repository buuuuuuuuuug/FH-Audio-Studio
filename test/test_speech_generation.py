"""Synthesis queue/data-flow tests use real PCM, without model/network access."""

import json
import threading
import time
from pathlib import Path
from test.test_voices import resource

import numpy as np
import pytest
import soundfile as sf

from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.speech_generation import Engine, GenerationWorkspace, parameters
from backend.fh_radio_studio_cli.voices import import_assets, load_plan, plan_path, prepare


class TestEngine(Engine):
    __test__ = False

    def __init__(self, home):
        super().__init__(home)
        self.calls = []
        self.presets_used = []
        self.fail = 0
        self.hold = None

    def settings(self):
        return {
            "presets": [
                {
                    "id": "p",
                    "name": "Test",
                    "version": "v2ProPlus",
                    "parameters": {},
                    "text_lang": "all_ja",
                }
            ]
        }

    def generate(self, preset, text, language, params, output):
        self.calls.append((text, params.copy()))
        self.presets_used.append(preset.copy())
        if self.hold:
            self.hold.wait(3)
        if self.fail:
            self.fail -= 1
            raise CliError("temporary failure")
        sf.write(output, 0.1 * np.sin(np.arange(24000) * 0.1), 24000, subtype="PCM_16")

    def stop(self):
        if self.hold:
            self.hold.set()
        super().stop()


@pytest.fixture
def workspace(tmp_path):
    engine = TestEngine(tmp_path / "engine")
    project = tmp_path / "project"
    project.mkdir()
    work = GenerationWorkspace(project, engine)
    yield work
    work.close()


def wait(work):
    until = time.monotonic() + 5
    while any(j["status"] in ("queued", "running") for j in work.status()["jobs"]):
        assert time.monotonic() < until
        time.sleep(0.01)
    return work.status()["jobs"]


def submit(work, **options):
    return work.submit(
        {"preset_id": "p", "entries": [{"text": "こんにちは", "name": "Test"}], **options}
    )


def test_preset_selection_persists_in_project(workspace):
    workspace.action("select-preset", {"id": "p"})
    assert workspace.status()["selected_preset_id"] == "p"
    assert json.loads((workspace.folder / "selection.json").read_text(encoding="utf-8")) == {
        "preset_id": "p"
    }
    with pytest.raises(CliError, match="预设不存在"):
        workspace.action("select-preset", {"id": "missing"})
    assert workspace.status()["selected_preset_id"] == "p"


def test_delete_generated_file_removes_adopted_copy_and_references(workspace):
    from backend.fh_radio_studio_cli.stingers import _write, local_file

    submit(workspace)
    job = wait(workspace)[-1]
    candidate = job["candidates"][0]
    result = workspace.accept({"job_id": job["id"], "candidate_id": candidate["id"]})
    asset = result["asset"]
    owned = local_file(workspace.project, asset["source"])
    plan = result["plan"]
    plan["banks"]["test"] = {"replacements": {"0": result["edit"]}}
    _write(plan_path(workspace.project), plan)
    deleted = workspace.action(
        "delete-candidate", {"job_id": job["id"], "candidate_id": candidate["id"]}
    )
    assert deleted["removed_asset_ids"] == [asset["id"]]
    assert not owned.exists()
    assert not Path(candidate["path"]).exists()
    assert not deleted["plan"]["banks"]["test"]["replacements"]
    assert not workspace.jobs[-1]["candidates"]
    assert workspace.jobs[-1]["preview_deleted"] is True


@pytest.mark.parametrize(
    "bad",
    [
        {"seed": True},
        {"temperature": float("nan")},
        {"top_k": 1.5},
        {"top_p": 0},
        {"batch_size": 201},
        {"speed_factor": -1},
        {"text_split_method": "arbitrary"},
        {"parallel_infer": 1},
        {"sample_steps": 10},
        {"device": "bogus"},
    ],
)
def test_invalid_parameters_never_reach_engine(bad):
    with pytest.raises(CliError):
        parameters(bad)


def test_unsupported_parameters_are_disabled_and_streaming_is_gated():
    value = parameters({"super_sampling": True, "cfg_rate": 1.5, "sample_steps": 8})
    assert (
        value["super_sampling"] is False and value["cfg_rate"] == 0 and value["sample_steps"] == 32
    )
    with pytest.raises(CliError):
        parameters({"gpt_streaming": True, "streaming_mode": 2, "batch_size": 2})


def test_candidates_are_complete_wavs_and_do_not_create_saved_replacements(workspace):
    submit(workspace, candidate_count=2, parameters={"seed": 42})
    job = wait(workspace)[0]
    assert job["status"] == "ready"
    assert [c["seed"] for c in job["candidates"]] == [42, 43]
    assert all(sf.info(c["path"]).frames == 24000 for c in job["candidates"])
    assert not (workspace.project / ".fh-radio-studio/voices.json").exists()
    result = workspace.accept({"job_id": job["id"], "candidate_id": job["candidates"][0]["id"]})
    asset = result["asset"]
    assert asset["generation"]["text"] == "こんにちは"
    assert asset["duration"] == 1
    assert result["edit"]["keep_duration"] is False
    assert not load_plan(workspace.project)["banks"]
    assert len(load_plan(workspace.project)["assets"]) == 1
    workspace.action("clear-candidates", {})
    assert not Path(job["candidates"][0]["path"]).exists()
    assert list((workspace.project / "sources/voices").glob("*.wav"))


def test_batch_fifo_retries_only_failed_generation_and_preserves_success(workspace):
    workspace.engine.fail = 1
    submit(workspace, entries=[{"text": "one"}, {"text": "two"}])
    jobs = wait(workspace)
    assert [j["status"] for j in jobs] == ["ready", "ready"]
    assert [c[0] for c in workspace.engine.calls] == ["one", "one", "two"]


def test_pause_resume_persistence_and_cancel(workspace):
    workspace.engine.hold = threading.Event()
    submit(workspace, entries=[{"text": "first"}, {"text": "second"}])
    deadline = time.monotonic() + 2
    while not workspace.engine.calls:
        assert time.monotonic() < deadline
        time.sleep(0.01)
    workspace.action("pause", {})
    workspace.engine.hold.set()
    time.sleep(0.03)
    assert len(workspace.engine.calls) == 1
    assert workspace.jobs[1]["status"] == "queued"
    workspace.engine.hold = None
    workspace.action("resume", {})
    assert all(j["status"] == "ready" for j in wait(workspace))
    workspace.engine.hold = threading.Event()
    submit(workspace)
    deadline = time.monotonic() + 2
    while workspace.jobs[-1]["status"] != "running":
        assert time.monotonic() < deadline
        time.sleep(0.01)
    workspace.action("cancel", {})
    assert workspace.jobs[-1]["status"] == "cancelled"
    time.sleep(0.05)
    assert not workspace.jobs[-1]["candidates"]


def test_preview_dismissal_persists_without_deleting_generated_file(workspace):
    submit(workspace)
    job = wait(workspace)[0]
    source = Path(job["candidates"][0]["path"])
    workspace.action("acknowledge", {"preview_job_ids": [job["id"]]})
    assert source.is_file()
    recorded = json.loads(workspace.path.read_text(encoding="utf-8"))["jobs"][0]
    assert recorded["preview_dismissed"] is True
    assert recorded["candidates"][0]["path"] == str(source)
    assert workspace.jobs[0]["status"] == "ready"


def test_restart_pauses_unfinished_work(tmp_path):
    path = tmp_path / "analysis/voices/generation/jobs.json"
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps({"jobs": [{"id": "a" * 32, "status": "running"}]}))
    w = GenerationWorkspace(tmp_path, TestEngine(tmp_path / "engine"))
    try:
        assert w.status()["jobs"][0]["status"] == "paused"
        assert w.status()["paused"] is True
    finally:
        w.close()


def test_closing_a_running_job_preserves_paused_state(workspace):
    workspace.engine.hold = threading.Event()
    submit(workspace)
    until = time.monotonic() + 2
    while not workspace.engine.calls:
        assert time.monotonic() < until
        time.sleep(0.01)
    workspace.close()
    saved = json.loads(workspace.path.read_text(encoding="utf-8"))
    assert saved["jobs"][0]["status"] == "paused"
    assert not saved["jobs"][0].get("error")


def test_cleanup_never_follows_outside_paths(workspace):
    sentinel = workspace.folder.parent / "keep.wav"
    sentinel.parent.mkdir(parents=True, exist_ok=True)
    sentinel.write_bytes(b"user data")
    workspace.jobs.append({"id": "..", "status": "ready", "candidates": []})
    workspace.action("clear-candidates", {})
    assert sentinel.read_bytes() == b"user data"


def test_target_fingerprint_and_saved_mapping_are_preserved(resource):
    project, game, source = resource
    prepared = prepare(project, game, source)
    bank = prepared["bank"]
    w = GenerationWorkspace(project, TestEngine(project / "engine"))
    try:
        target = {"bank_id": bank["id"], "sha256": bank["sha256"], "index": 1, "expected": None}
        with pytest.raises(CliError):
            submit(w, entries=[{"text": "x", "target": {**target, "sha256": "bad"}}])
        submit(w, entries=[{"text": "x", "target": target}])
        job = wait(w)[0]
        result = w.accept({"job_id": job["id"], "candidate_id": job["candidates"][0]["id"]})
        assert result["target"] == target
        assert not load_plan(project)["banks"][bank["id"]]["replacements"]
        assert source.is_file()
    finally:
        w.close()


def test_adopting_duplicate_audio_preserves_user_asset_name_and_provenance(workspace):
    submit(workspace)
    job = wait(workspace)[0]
    imported = import_assets(workspace.project, [job["candidates"][0]["path"]], "User folder")
    imported["plan"]["assets"][0]["name"] = "My original name"
    plan_path(workspace.project).write_text(json.dumps(imported["plan"]), encoding="utf-8")
    result = workspace.accept({"job_id": job["id"], "candidate_id": job["candidates"][0]["id"]})
    assert result["asset"]["name"] == "My original name"
    assert "generation" not in result["asset"]
    assert result["previous_edit"] is None
    again = workspace.accept({"job_id": job["id"], "candidate_id": job["candidates"][0]["id"]})
    assert again["previous_edit"] == result["edit"]


def test_removed_game_reference_is_not_read_or_used(workspace, monkeypatch):
    def unexpected(*args):
        raise AssertionError("Game original must never be opened as reference")

    monkeypatch.setattr("backend.fh_radio_studio_cli.voices.original", unexpected)
    submit(workspace, original_reference=True)
    assert wait(workspace)[0]["status"] == "ready"
    assert workspace.engine.presets_used[0] == workspace.engine.settings()["presets"][0]


def test_legacy_original_reference_job_restores_with_preset_notice(tmp_path):
    path = tmp_path / "analysis/voices/generation/jobs.json"
    path.parent.mkdir(parents=True)
    path.write_text(
        json.dumps({"jobs": [{"id": "a" * 32, "status": "running", "original_reference": True}]})
    )
    work = GenerationWorkspace(tmp_path, TestEngine(tmp_path / "engine"))
    try:
        job = work.status()["jobs"][0]
        assert job["status"] == "paused"
        assert "original_reference" not in job
        assert "声音预设" in job["notice"]
    finally:
        work.close()


def test_reference_validation_and_presets_are_owned_not_linked(tmp_path):
    engine = Engine(tmp_path / "engine")
    gpt, sovits, ref = [tmp_path / n for n in ("speaker.ckpt", "speaker.pth", "ref.wav")]
    gpt.write_bytes(b"test gpt")
    sovits.write_bytes(b"test sovits")
    data = dict(
        name="voice",
        gpt_model=str(gpt),
        sovits_model=str(sovits),
        ref_audio_path=str(ref),
        prompt_text="hello",
        text_lang="en",
    )
    sf.write(ref, np.zeros(24000), 24000)
    with pytest.raises(CliError, match="3–10"):
        engine.save_preset(data)
    sf.write(ref, np.sin(np.arange(96000) * 0.1) * 0.1, 24000)
    preset = engine.save_preset(data)
    gpt.unlink()
    assert (engine.home / preset["gpt_model"]).read_bytes() == b"test gpt"
    assert (engine.home / preset["ref_audio_path"]).is_file()


def test_acknowledgement_is_separate_from_material_adoption(workspace):
    submit(workspace, auto_apply=True)
    job = wait(workspace)[0]
    assert job["auto_apply"] is False
    assert load_plan(workspace.project)["assets"] == []
    workspace.accept({"job_id": job["id"], "candidate_id": job["candidates"][0]["id"]})
    assert not job.get("consumed")
    workspace.action("acknowledge", {"job_id": job["id"]})
    assert workspace.status()["jobs"][0]["consumed"] is True


def test_legacy_pending_auto_apply_recovers_as_preview(workspace):
    submit(workspace)
    job = wait(workspace)[0]
    workspace.close()
    job["auto_apply"] = True
    workspace.path.write_text(json.dumps({"jobs": [job]}), encoding="utf-8")
    recovered = GenerationWorkspace(workspace.project, workspace.engine)
    try:
        result = recovered.status()["jobs"][0]
        assert result["auto_apply"] is False
        assert result["candidates"] == job["candidates"]
        assert "预览" in result["notice"]
        assert load_plan(workspace.project)["assets"] == []
    finally:
        recovered.close()


def test_filename_metadata_and_preset_deletion_keep_managed_files(tmp_path):
    engine = Engine(tmp_path / "engine")
    paths = [
        tmp_path / name
        for name in ("原始 GPT.ckpt", "原始 SoVITS.pth", "参考.wav", "辅助一.wav", "辅助二.wav")
    ]
    paths[0].write_bytes(b"gpt")
    paths[1].write_bytes(b"sovits")
    for i, path in enumerate(paths[2:]):
        sf.write(path, np.sin(np.arange(96000) * (0.1 + i * 0.01)) * 0.1, 24000)
    preset = engine.save_preset(
        dict(
            name="test",
            gpt_model=str(paths[0]),
            sovits_model=str(paths[1]),
            ref_audio_path=str(paths[2]),
            prompt_text="hello",
            aux_ref_audio_paths=[str(p) for p in paths[3:]],
        )
    )
    assert preset["gpt_filename"] == paths[0].name
    assert preset["sovits_filename"] == paths[1].name
    assert preset["reference_filename"] == paths[2].name
    assert preset["aux_reference_filenames"] == [p.name for p in paths[3:]]
    roundtrip = engine.prepare_config(preset)
    assert roundtrip["aux_reference_filenames"] == preset["aux_reference_filenames"]
    missing = {k: v for k, v in preset.items() if "filename" not in k and "label" not in k}
    unknown = engine.prepare_config(missing)
    assert unknown["gpt_filename"] is None
    assert unknown["reference_filename"] is None
    owned = [engine.home / preset[k] for k in ("gpt_model", "sovits_model", "ref_audio_path")] + [
        engine.home / p for p in preset["aux_ref_audio_paths"]
    ]
    workspace = GenerationWorkspace(tmp_path / "project", engine)
    try:
        workspace.action("delete-preset", {"id": preset["id"]})
        assert engine.settings()["presets"] == []
        assert all(p.is_file() for p in owned)
    finally:
        workspace.close()


def test_unsaved_working_configuration_does_not_create_or_overwrite_preset(workspace, tmp_path):
    engine = workspace.engine
    gpt, sovits, ref = [tmp_path / n for n in ("speaker.ckpt", "speaker.pth", "ref.wav")]
    gpt.write_bytes(b"test gpt")
    sovits.write_bytes(b"test sovits")
    sf.write(ref, np.sin(np.arange(96000) * 0.1) * 0.1, 24000)
    config = dict(
        name="Working",
        gpt_model=str(gpt),
        sovits_model=str(sovits),
        ref_audio_path=str(ref),
        prompt_text="reference",
        text_lang="en",
        parameters={"speed_factor": 1.35, "seed": 17},
    )
    workspace.submit({"config": config, "count": 2, "entries": [{"text": "hello"}]})
    job = wait(workspace)[0]
    assert job["preset"]["name"] == "Working"
    assert job["parameters"]["speed_factor"] == 1.35
    assert [c["seed"] for c in job["candidates"]] == [17, 18]
    assert not engine.config_path.exists()
    assert engine.settings()["presets"][0]["name"] == "Test"


def test_duplicate_preset_name_requires_explicit_existing_id(tmp_path):
    engine = Engine(tmp_path / "engine")
    gpt, sovits, ref = [tmp_path / n for n in ("speaker.ckpt", "speaker.pth", "ref.wav")]
    gpt.write_bytes(b"gpt")
    sovits.write_bytes(b"sovits")
    sf.write(ref, np.sin(np.arange(96000) * 0.1) * 0.1, 24000)
    config = dict(
        name="Voice",
        gpt_model=str(gpt),
        sovits_model=str(sovits),
        ref_audio_path=str(ref),
        prompt_text="hello",
        text_lang="en",
    )
    preset = engine.save_preset(config)
    with pytest.raises(CliError, match="名称已存在"):
        engine.save_preset(config)
    changed = engine.save_preset({**preset, "parameters": {"speed_factor": 1.2}})
    assert changed["id"] == preset["id"]
    assert engine.settings()["presets"] == [changed]


def test_generated_audio_edits_reuse_material_renderer_and_adopt_only_edited_file(
    workspace, monkeypatch, tmp_path
):
    import os
    import shutil

    from backend.fh_radio_studio_cli.stingers import digest, local_file

    tools = os.environ.get("FH_RADIO_STUDIO_AUDIO_TOOLS_DIR")
    executable = (
        Path(tools) / "ffmpeg/ffmpeg.exe"
        if tools
        else Path(shutil.which("ffmpeg") or "missing-ffmpeg")
    )
    if not executable.is_file():
        pytest.skip("requires the bundled audio tools for real PCM integration")
    monkeypatch.setenv("FH_RADIO_STUDIO_AUDIO_TOOLS_DIR", str(executable.parent.parent))
    submit(workspace)
    job = wait(workspace)[0]
    audio = job["candidates"][0]
    before = digest(Path(audio["path"]))
    request = {"job_id": job["id"], "candidate_id": audio["id"]}
    original = workspace.candidate_audio(request)
    assert original["duration"] == 1
    edit = {
        "audio_edits": [
            {"kind": "insert", "at": 0.2, "duration": 0.1},
            {"kind": "silence", "start": 0.6, "end": 0.7},
            {"kind": "delete", "start": 0.8, "end": 0.9},
        ]
    }
    wave = workspace.candidate_audio({**request, "edit": edit})
    assert wave["duration"] == pytest.approx(1)
    assert workspace.candidate_audio({**request, "edit": edit})["path"] == wave["path"]
    pcm, rate = sf.read(wave["path"])
    assert rate == 48000
    assert not pcm[9600:14400].any() and not pcm[28800:33600].any()
    assert np.max(np.abs(pcm[:9000])) > 0.01
    exported = tmp_path / "edited.wav"
    workspace.action("export-audio", {**request, "edit": edit, "path": str(exported)})
    accepted = workspace.accept({**request, "edit": edit})
    adopted = local_file(workspace.project, accepted["asset"]["source"])
    assert digest(adopted) == digest(exported)
    assert digest(Path(audio["path"])) == before
    assert len(load_plan(workspace.project)["assets"]) == 1


def test_generation_uses_natural_duration_even_for_legacy_fit_request(workspace):
    submit(
        workspace,
        fit_duration=True,
        entries=[{"text": "new voice", "duration": 0.7}],
        parameters={"speed_factor": 1.0},
    )
    job = wait(workspace)[0]
    assert job["status"] == "ready"
    assert len(workspace.engine.calls) == 1
    assert job["candidates"][0]["duration"] == 1.0
    assert job["candidates"][0]["parameters"]["speed_factor"] == 1.0
