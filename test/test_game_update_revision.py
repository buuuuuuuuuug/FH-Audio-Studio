import argparse
import contextlib
import io
import json
from pathlib import Path
from test.test_stinger_bank import bank
from test.test_stinger_composition import draft

import pytest

from backend.fh_radio_studio_cli.common import CliError, md5_file
from backend.fh_radio_studio_cli.deploy import cmd_deploy_package
from backend.fh_radio_studio_cli.game_update import stamp_package_inputs, validate_package_inputs
from backend.fh_radio_studio_cli.package import collect_package_deploy_files
from backend.fh_radio_studio_cli.stingers import _write
from backend.fh_radio_studio_cli.voices import load_plan, plan_path, prepare, scan


def layout(tmp_path):
    game, package = tmp_path / "game", tmp_path / "package"
    relative = "media/audio/FMODBanks/VO_Test_JP.assets.bank"
    for root in (game, package):
        path = root / relative
        path.parent.mkdir(parents=True)
        path.write_bytes(bank(["a", "b"]))
    (package / "fh_radio_studio_package_manifest.json").write_text("{}")
    return game, package, relative


def test_changed_only_deploy_omits_identical_base_and_existing_overlay(tmp_path, capsys):
    game, package, relative = layout(tmp_path)
    args = argparse.Namespace(
        game_dir=str(game),
        package_dir=str(package),
        target_root="mediapc",
        yes=False,
        json=True,
        force=False,
        baseline_manifest=None,
        last_applied_manifest=None,
    )
    cmd_deploy_package(args)
    preview = json.loads(capsys.readouterr().out)
    assert preview["resource_count"] == 0
    assert preview["omitted_unchanged_count"] == 1
    overlay = game / relative.replace("media/", "mediapc/", 1)
    overlay.parent.mkdir(parents=True)
    overlay.write_bytes(b"custom")
    (package / relative).write_bytes(b"custom")
    cmd_deploy_package(args)
    assert json.loads(capsys.readouterr().out)["resource_count"] == 0
    assert not (game / "deploy_manifest.json").exists()


def test_game_update_rejects_old_package_even_when_old_override_masks_update(tmp_path):
    game, package, relative = layout(tmp_path)
    stamp_package_inputs(game, package)
    manifest = json.loads((package / "fh_radio_studio_package_manifest.json").read_text())
    overlay = game / relative.replace("media/", "mediapc/", 1)
    overlay.parent.mkdir(parents=True)
    overlay.write_bytes(b"old mod")
    (game / relative).write_bytes(bank(["a", "new", "b"]))
    with pytest.raises(CliError, match="游戏原文件在构建后已更新"):
        validate_package_inputs(manifest, game, collect_package_deploy_files(package))


def test_updated_voice_bank_remaps_saved_and_draft_by_name_and_keeps_old_backup(tmp_path):
    game, _, relative = layout(tmp_path)
    project = tmp_path / "project"
    (project / ".fh-radio-studio").mkdir(parents=True)
    result = prepare(project, game, game / relative)
    identity, sha = result["bank"]["id"], result["bank"]["sha256"]
    plan = load_plan(project)
    edit = {"asset_id": "kept", "gain_db": 0}
    plan["banks"][identity]["replacements"] = {"1": edit}
    _write(plan_path(project), plan)
    draft = {"version": 1, "edits": {identity: {"0": edit}}, "saved": {identity: {"1": edit}}}
    _write(project / "analysis/voices/draft.json", draft)
    (game / relative).write_bytes(bank(["b", "new", "a"]))
    after = scan(project, game)
    current = after["plan"]["banks"][identity]
    assert current["sha256"] != sha
    assert current["replacements"] == {"0": edit}
    assert (project / f".fh-radio-studio/voices/baselines/{sha}.bank").exists()
    updated_draft = json.loads((project / "analysis/voices/draft.json").read_text())
    assert updated_draft["edits"][identity] == {"2": edit}
    assert len(after["catalogs"][identity]["entries"]) == 3


def test_removed_or_ambiguous_voice_entry_is_archived_not_assigned_by_index(tmp_path):
    game, _, relative = layout(tmp_path)
    project = tmp_path / "project"
    result = prepare(project, game, game / relative)
    identity = result["bank"]["id"]
    plan = load_plan(project)
    plan["banks"][identity]["replacements"] = {"1": {"asset_id": "retained-in-history"}}
    _write(plan_path(project), plan)
    (game / relative).write_bytes(bank(["a", "unrelated"]))
    current = scan(project, game)["plan"]["banks"][identity]
    assert current["replacements"] == {}
    assert current["update_conflicts"] == ["1"]
    archive = Path(current["update_history"][-1]["archive"])
    assert (
        json.loads(archive.read_text(encoding="utf-8"))["bank"]["replacements"]["1"]["asset_id"]
        == "retained-in-history"
    )


def test_language_detection_reads_display_and_voice_independently(tmp_path, monkeypatch):
    from backend.fh_radio_studio_cli import status
    from backend.fh_radio_studio_cli.language import normalize_text_language

    game, _, _ = layout(tmp_path)
    xml = game / "media/audio/RadioInfo_JP.xml"
    xml.write_text(
        '<R><RadioStations><RadioStation Number="9" Name="Radio" /></RadioStations></R>',
        encoding="utf-8",
    )
    preferred = tmp_path / "UserPreferredLang"
    preferred.write_text("CHS", encoding="utf-8")
    audio = preferred.with_name("UserPreferredAudioLang")
    audio.write_text("JP", encoding="utf-8")
    monkeypatch.setattr(status, "collect_tool_status", lambda: ({}, True))
    monkeypatch.setattr(status, "is_forza_running", lambda: False)
    args = argparse.Namespace(
        game_dir=str(game), source="EN", target="CHS", preferred_path=str(preferred), radio=None
    )
    result = status.build_status_payload(args)
    assert result["language"]["source_lang"] == "CHS"
    assert result["language"]["target_lang"] == "JP"
    audio.write_text("EN", encoding="utf-8")
    assert status.build_status_payload(args)["language"]["target_lang"] == "EN"
    assert preferred.read_text(encoding="utf-8") == "CHS"


def test_both_language_preference_files_are_excluded():
    from backend.fh_radio_studio_cli.language_policy import is_language_support_file

    for name in [
        "UserPreferredLang",
        "UserPreferredAudioLang",
        "media/Stripped/StringTables/JP.zip",
    ]:
        assert is_language_support_file(name)


def test_forced_baseline_refresh_preserves_prepared_work(tmp_path, monkeypatch):
    from test.test_backend_transactions import make_baseline

    from backend.fh_radio_studio_cli import baseline

    game, backup, files = make_baseline(tmp_path)
    original_plan = {
        "game_version": {},
        "files": [
            dict(
                item,
                source_game_path=str(game / item["install_relative_path"]),
                md5=md5_file(game / item["install_relative_path"]),
            )
            for item in files
        ],
    }
    monkeypatch.setattr(baseline, "baseline_plan", lambda *args, **kwargs: original_plan)
    project = tmp_path / "Project"
    backup = project / "backups/baseline-current"
    prepared = project / "packages/current/keep.txt"
    prepared.parent.mkdir(parents=True)
    prepared.write_text("preserve package", encoding="utf-8")
    draft = project / ".fh-radio-studio/last_applied_package_manifest.json"
    draft.parent.mkdir(parents=True)
    draft.write_text('{"preserve":"ownership"}', encoding="utf-8")
    args = argparse.Namespace(
        baseline_action="create",
        game_dir=str(game),
        package_dir=None,
        out_dir=str(backup),
        preferred_path=None,
        jobs=1,
        progress_jsonl=False,
        overwrite=True,
        state="current",
        yes=True,
    )
    baseline.cmd_baseline(args)
    assert prepared.read_text(encoding="utf-8") == "preserve package"
    assert json.loads(draft.read_text(encoding="utf-8")) == {"preserve": "ownership"}


def test_stinger_update_refreshes_original_and_preserves_sound_assignments(draft):
    import shutil

    from backend.fh_radio_studio_cli.game_update import synchronize_stingers
    from backend.fh_radio_studio_cli.stingers import freeze_for_build
    from backend.fh_radio_studio_cli.stingers import load_plan as stinger_plan

    project, _, xml, old, args = draft
    game = project / "Game"
    target = game / "media/audio/FMODBanks/R9_Stingers_JP.assets.bank"
    target.parent.mkdir(parents=True)
    target.write_bytes(bank(["c", "b", "a"]))
    shutil.copy2(xml, game / "media/audio/RadioInfo_JP.xml")
    after = synchronize_stingers(project, game)
    assert after["assignments"] == old["assignments"]
    assert after["baselines"]["R9:JP"]["sha256"] != old["baselines"]["R9:JP"]["sha256"]
    args.game_dir = str(game)
    assert freeze_for_build(args)["plan"]["assignments"] == old["assignments"]


def test_integrity_detects_updated_base_hidden_by_owned_overlay(tmp_path, monkeypatch):
    from backend.fh_radio_studio_cli import integrity

    game, _, relative = layout(tmp_path)
    old = md5_file(game / relative)
    baseline = tmp_path / "baseline.json"
    _write(baseline, {"files": [{"install_relative_path": relative, "md5": old}]})
    overlay_relative = relative.replace("media/", "mediapc/", 1)
    overlay = game / overlay_relative
    overlay.parent.mkdir(parents=True)
    overlay.write_bytes(b"owned old overlay")
    applied = tmp_path / "last.json"
    _write(
        applied,
        {"package_files": [{"install_relative_path": overlay_relative, "md5": md5_file(overlay)}]},
    )
    (game / relative).write_bytes(b"new official game audio")
    monkeypatch.setattr(
        integrity,
        "baseline_plan",
        lambda *a, **kw: {
            "game_version": {},
            "files": [
                {
                    "relative_path": relative,
                    "install_relative_path": relative,
                    "source_game_path": str(game / relative),
                    "md5": md5_file(game / relative),
                    "backup_md5": old,
                    "recorded_baseline_md5": old,
                    "baseline_status": "backup_differs_from_current",
                }
            ],
        },
    )
    result = integrity.verify_integrity(
        game, baseline_manifest=baseline, last_applied_package_manifest=applied
    )
    assert result["integrity"]["level"] == "game_changed"
    assert result["integrity"]["base_file_updates"]


def test_imported_materials_keep_readable_names(tmp_path):
    import numpy as np
    import soundfile as sf

    from backend.fh_radio_studio_cli.stingers import import_audio
    from backend.fh_radio_studio_cli.voices import import_assets

    source = tmp_path / "001 Original voice.wav"
    sf.write(source, np.zeros(4800), 48000)
    project = tmp_path / "Project"
    for result in (import_assets(project, [source], "test"), import_audio(project, [source])):
        asset = result.get("plan", result)["assets"][0]
        from backend.fh_radio_studio_cli.stingers import local_file

        assert local_file(project, asset["source"]).stem.startswith("001 Original voice_")
        assert local_file(project, asset["source"]).is_file()
