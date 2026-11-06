import base64
import csv
import io
import json
from pathlib import Path
from test.test_stinger_bank import bank
from test.test_voice_text_index import resources
from types import SimpleNamespace
from zipfile import ZipFile

import pytest

from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.voice_text import attach_dialogue, dialogue_stamp
from backend.fh_radio_studio_cli.voice_workspace import cached_catalogs, export_text
from backend.fh_radio_studio_cli.voices import load_plan, original, prepare, scan


def setup_resource(tmp_path):
    game = resources(
        tmp_path,
        '<R><Event name="Group/voice" sub="42"/></R>',
        {
            "JP": {"Dialogue_Gameplay.str": {42: "確認"}},
            "EN": {"Dialogue_Gameplay.str": {42: "Confirm"}},
            "CHS": {"Dialogue_Gameplay.str": {42: "确认"}},
            "DE": {"Dialogue_Gameplay.str": {42: "Bestätigen"}},
        },
    )
    source = game / "media/audio/FMODBanks/VO_Test_JP.assets.bank"
    source.parent.mkdir(parents=True)
    source.write_bytes(bank(["voice_JP"]))
    project = tmp_path / "Project"
    (project / ".fh-radio-studio").mkdir(parents=True)
    return project, game, source


def test_language_change_selects_matching_audio_not_just_subtitles(tmp_path):
    project, game, japanese = setup_resource(tmp_path)
    chinese = japanese.with_name("VO_Test_CN.assets.bank")
    chinese.write_bytes(bank(["voice_CN"]))
    jp = prepare(project, game, japanese)
    cn = prepare(project, game, chinese)
    result = scan(
        project,
        game,
        selected_path=cn["bank"]["relative_path"],
        follow_voice_language=True,
        voice_language="JP",
        display_language="CHS",
    )
    assert result["selected_file"]["name"] == japanese.name
    assert result["active"]["bank"]["id"] == jp["bank"]["id"]
    assert result["active"]["entries"][0]["name"] == "voice_JP"


def test_original_audition_maps_sound_identity_instead_of_reusing_chinese_index(
    tmp_path, monkeypatch
):
    project, game, japanese = setup_resource(tmp_path)
    chinese = japanese.with_name("VO_Test_CN.assets.bank")
    chinese.write_bytes(bank(["other_CN", "voice_CN"]))
    jp = prepare(project, game, japanese)
    cn = prepare(project, game, chinese)
    calls = []

    def decode(command):
        calls.append(command)
        Path(command[command.index("-o") + 1]).write_bytes(b"japanese decoded audio")

    monkeypatch.setattr("backend.fh_radio_studio_cli.voices._run", decode)
    monkeypatch.setattr("backend.fh_radio_studio_cli.voices._tool", lambda *a: "decoder")
    result = original(
        SimpleNamespace(game_dir=str(game)), project, cn["bank"]["id"], 1, voice_language="JP"
    )
    assert result["bank_id"] == jp["bank"]["id"]
    assert result["index"] == 0
    assert calls[0][calls[0].index("-s") + 1] == 1
    assert result["voice_language"] == "JP"


def test_original_audition_never_falls_back_to_chinese_or_guessing_by_index(tmp_path, monkeypatch):
    project, game, japanese = setup_resource(tmp_path)
    chinese = japanese.with_name("VO_Test_CN.assets.bank")
    chinese.write_bytes(bank(["missing_CN"]))
    cn = prepare(project, game, chinese)
    with pytest.raises(CliError, match="唯一 JP 原音"):
        original(
            SimpleNamespace(game_dir=str(game)), project, cn["bank"]["id"], 0, voice_language="JP"
        )


def test_requested_text_languages_do_not_change_bank_hash_matching(tmp_path):
    project, game, source = setup_resource(tmp_path)
    parsed = prepare(project, game, source, voice_language="EN", display_language="DE")
    entry = parsed["entries"][0]
    assert entry["content"] == "Confirm"
    assert entry["translation"] == "Bestätigen"
    assert entry["name"] == "voice_JP"
    assert (entry["content_language"], entry["translation_language"]) == ("EN", "DE")


def test_original_audition_ignores_installed_override_and_keeps_edit_plan(tmp_path, monkeypatch):
    project, game, pristine = setup_resource(tmp_path)
    pristine.write_bytes(bank(["voice_JP", "other_JP"]))
    override = game / "mediapc/audio/FMODBanks" / pristine.name
    override.parent.mkdir(parents=True)
    override.write_bytes(bank(["other_JP", "voice_JP"]))
    parsed = prepare(project, game, override)
    before = (project / ".fh-radio-studio/voices.json").read_bytes()
    stale = project / f"analysis/voices/original/{parsed['bank']['sha256']}/2.wav"
    stale.parent.mkdir(parents=True)
    stale.write_bytes(b"old replacement audition")
    calls = []

    def decode(command):
        calls.append(command)
        assert Path(command[-1]).read_bytes() == pristine.read_bytes()
        Path(command[command.index("-o") + 1]).write_bytes(b"pristine audition")

    monkeypatch.setattr("backend.fh_radio_studio_cli.voices._run", decode)
    monkeypatch.setattr("backend.fh_radio_studio_cli.voices._tool", lambda *a: "decoder")
    result = original(
        SimpleNamespace(game_dir=str(game)), project, parsed["bank"]["id"], 1, voice_language="JP"
    )
    assert result["index"] == 0
    assert result["source_kind"] == "game-original"
    assert Path(result["path"]).read_bytes() == b"pristine audition"
    assert calls[0][calls[0].index("-s") + 1] == 1
    assert stale.read_bytes() == b"old replacement audition"
    assert (project / ".fh-radio-studio/voices.json").read_bytes() == before


def test_original_audition_does_not_guess_when_pristine_sound_is_missing(tmp_path):
    project, game, pristine = setup_resource(tmp_path)
    override = game / "mediapc/audio/FMODBanks" / pristine.name
    override.parent.mkdir(parents=True)
    override.write_bytes(bank(["replacement_only_JP"]))
    parsed = prepare(project, game, override)
    with pytest.raises(CliError, match="未使用覆盖文件或按序号猜测"):
        original(
            SimpleNamespace(game_dir=str(game)),
            project,
            parsed["bank"]["id"],
            0,
            voice_language="JP",
        )


def test_switching_languages_refreshes_saved_catalog_and_preserves_audio_edits(tmp_path):
    project, game, source = setup_resource(tmp_path)
    parsed = prepare(project, game, source)
    plan = load_plan(project)
    key = parsed["bank"]["id"]
    plan["banks"][key]["replacements"] = {"0": {"asset_id": "retained"}}
    original = source.read_bytes()
    for voice, display, expected in [
        ("EN", "DE", ("Confirm", "Bestätigen")),
        ("JP", "CHS", ("確認", "确认")),
        ("EN", "EN", ("Confirm", "Confirm")),
    ]:
        item = cached_catalogs(project, plan, game, voice_language=voice, display_language=display)[
            key
        ]
        assert (item["entries"][0]["content"], item["entries"][0]["translation"]) == expected
        assert item["bank"]["replacements"] == {"0": {"asset_id": "retained"}}
    assert source.read_bytes() == original


def test_missing_requested_language_does_not_keep_old_chinese_text(tmp_path):
    _, game, source = setup_resource(tmp_path)
    entries = [{"index": 0, "name": "voice_JP", "translation": "旧中文"}]
    attach_dialogue(
        game, source, source.read_bytes(), entries, voice_language="JP", display_language="FR"
    )
    assert entries[0]["content"] == "確認"
    assert entries[0]["translation"] == ""
    assert "显示语言" in entries[0]["text_reason"]
    assert dialogue_stamp(game, source, display_language="FR") != dialogue_stamp(game, source)


def test_exports_use_selected_languages_and_have_no_resource_column(tmp_path):
    project, game, source = setup_resource(tmp_path)
    parsed = prepare(project, game, source)
    result = export_text(
        project,
        game,
        {
            "sources": [str(source)],
            "bank_id": parsed["bank"]["id"],
            "voice_language": "EN",
            "display_language": "DE",
            "format": "xlsx",
        },
    )
    assert result["headers"] == ["序号", "条目", "语音语言", "显示语言", "时长（秒）"]
    assert result["rows"][0][2:4] == ["Confirm", "Bestätigen"]
    assert len(result["rows"][0]) == len(result["headers"])
    assert "资源文件" not in result["csv"]
    assert list(csv.reader(io.StringIO(result["csv"])))[0] == result["headers"]
    with ZipFile(io.BytesIO(base64.b64decode(result["xlsx_base64"]))) as archive:
        sheet = archive.read("xl/worksheets/sheet1.xml").decode("utf-8")
        assert "资源文件" not in sheet and "Bestätigen" in sheet
