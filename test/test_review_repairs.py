import argparse
import io
import json
from test.test_import_audio import _write_pcm_wav

import pytest

from backend.fh_radio_studio_cli import import_audio, stinger_worker
from backend.fh_radio_studio_cli.baseline import cmd_baseline
from backend.fh_radio_studio_cli.cli import build_parser
from backend.fh_radio_studio_cli.common import CliError


def test_language_path_survives_subcommand():
    parser = build_parser()
    assert (
        parser.parse_args(["language-swap", "--game-dir", "D:/Game", "list"]).game_dir == "D:/Game"
    )
    assert (
        parser.parse_args(["language-swap", "list", "--game-dir", "E:/Game"]).game_dir == "E:/Game"
    )


def test_kept_audio_survives_tag_write_failure(tmp_path, monkeypatch):
    source = tmp_path / "sources/song.wav"
    _write_pcm_wav(source, sample_rate=48000, frames=4800, channels=2)
    before = source.read_bytes()

    def fail(path, **kwargs):
        path.write_bytes(b"partial tag write")
        raise OSError("interrupted")

    monkeypatch.setattr(import_audio, "_write_import_tags", fail)
    with pytest.raises(OSError):
        import_audio.import_audio_file(source, source.parent, ffmpeg=None, title="new title")
    assert source.read_bytes() == before


def test_mono_48k_still_requires_conversion(tmp_path, monkeypatch):
    source = tmp_path / "mono.wav"
    _write_pcm_wav(source, sample_rate=48000, frames=4800, channels=1)

    def convert(*args, **kwargs):
        raise RuntimeError("conversion selected")

    monkeypatch.setattr(import_audio, "_transcode_to_48k", convert)
    with pytest.raises(RuntimeError, match="conversion selected"):
        import_audio.import_audio_file(source, tmp_path / "sources", ffmpeg=None)


def test_worker_survives_invalid_requests(monkeypatch):
    output = io.StringIO()
    monkeypatch.setattr(
        stinger_worker.sys,
        "stdin",
        io.StringIO('bad\n[]\n{}\n{"id":1,"action":"serve"}\n{"id":2,"action":"status"}\n'),
    )
    monkeypatch.setattr(stinger_worker.sys, "stdout", output)

    def handler(args):
        print(json.dumps({"ok": True}))
        return 0

    assert stinger_worker.serve(argparse.Namespace(), handler) == 0
    replies = [json.loads(line) for line in output.getvalue().splitlines()]
    assert all("error" in reply for reply in replies[:-1])
    assert replies[-1] == {"id": 2, "result": {"ok": True}}


def test_discard_rejects_unrelated_directory(tmp_path):
    keep = tmp_path / "important"
    keep.mkdir()
    (keep / "data.txt").write_text("keep")
    with pytest.raises(CliError):
        cmd_baseline(
            argparse.Namespace(baseline_action="discard-pending", pending_dir=str(keep), yes=True)
        )
    assert (keep / "data.txt").read_text() == "keep"


@pytest.mark.parametrize("state", ["current", "pending-verify"])
def test_discard_only_pending_baseline(tmp_path, state):
    project = tmp_path / "project"
    (project / ".fh-radio-studio").mkdir(parents=True)
    (project / ".fh-radio-studio/project.json").write_text("{}")
    pending = project / "backups/pending"
    pending.mkdir(parents=True)
    (pending / "baseline_manifest.json").write_text(
        json.dumps({"kind": "game_baseline", "state": state})
    )
    args = argparse.Namespace(baseline_action="discard-pending", pending_dir=str(pending), yes=True)
    if state == "current":
        with pytest.raises(CliError):
            cmd_baseline(args)
        assert pending.is_dir()
    else:
        assert cmd_baseline(args) == 0
        assert not pending.exists()


def test_mixed_restore_stays_in_delta_scope(tmp_path, monkeypatch):
    from backend.fh_radio_studio_cli import package

    scopes = []
    monkeypatch.setattr(
        package,
        "complete_package_from_baseline",
        lambda *a, **kw: scopes.append(kw["scoped_radios"]),
    )
    package.apply_baseline_completion(
        {"radios": [{"radio": 4}], "restored_radios": [{"radio": 9}]},
        tmp_path,
        argparse.Namespace(_stinger_snapshot={}, baseline_manifest=None),
    )
    assert scopes == [{4, 9}]
