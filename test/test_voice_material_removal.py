import json
from test.test_voices import resource

import numpy as np
import pytest
import soundfile as sf

from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.stingers import local_file
from backend.fh_radio_studio_cli.voice_workspace import remove_assets
from backend.fh_radio_studio_cli.voices import import_assets, plan_path, prepare, save


def test_material_removal_deletes_owned_copy_and_keeps_external_original(resource, tmp_path):
    project, game, source = resource
    bank = prepare(project, game, source)["bank"]
    paths = [tmp_path / "a.wav", tmp_path / "b.wav"]
    for i, path in enumerate(paths):
        sf.write(path, np.full(4800, i / 4), 48000)
    plan = import_assets(project, paths, "素材")["plan"]
    first, second = plan["assets"]
    changes = {
        str(i): {"asset_id": asset["id"], "start": 0, "end": 0.1, "gain_db": 0}
        for i, asset in enumerate([first, second])
    }
    save(project, {bank["id"]: changes})
    snapshot_path = local_file(project, first["source"])
    snapshot = snapshot_path.read_bytes()
    result = remove_assets(project, {"assets": [first["id"]]})
    assert result["removed"] == result["removed_replacements"] == 1
    assert result["plan"]["assets"] == [second]
    assert result["plan"]["banks"][bank["id"]]["replacements"] == {"1": changes["1"]}
    assert not snapshot_path.exists()
    assert paths[0].read_bytes() == snapshot
    assert local_file(project, second["source"]).is_file()
    assert (
        source.is_file()
        and json.loads(plan_path(project).read_text(encoding="utf-8")) == result["plan"]
    )


@pytest.mark.parametrize("ids", [[], [False], ["missing"], "all"])
def test_invalid_removal_never_changes_the_saved_plan(resource, ids):
    project, game, source = resource
    prepare(project, game, source)
    before = plan_path(project).read_bytes()
    with pytest.raises(CliError):
        remove_assets(project, {"assets": ids})
    assert plan_path(project).read_bytes() == before


def test_remove_keeps_shared_copy_until_last_reference_and_rolls_back_failure(
    resource, tmp_path, monkeypatch
):
    from pathlib import Path

    project, game, source = resource
    prepare(project, game, source)
    wav = tmp_path / "outside.wav"
    sf.write(wav, np.ones(4800) * 0.1, 48000)
    plan = import_assets(project, [wav], "素材")["plan"]
    original = plan["assets"][0]
    shared = {**original, "id": "shared"}
    plan["assets"].append(shared)
    plan_path(project).write_text(json.dumps(plan), encoding="utf-8")
    snapshot = local_file(project, original["source"])
    remove_assets(project, {"assets": [original["id"]]})
    assert snapshot.is_file()
    before = plan_path(project).read_bytes()
    rename = Path.rename

    def blocked(path, target):
        if path == snapshot:
            raise PermissionError("file in use")
        return rename(path, target)

    monkeypatch.setattr(Path, "rename", blocked)
    with pytest.raises(CliError, match="工程记录已保留"):
        remove_assets(project, {"assets": ["shared"]})
    assert plan_path(project).read_bytes() == before
    assert snapshot.is_file()
    assert wav.is_file()


def test_remove_never_unlinks_external_legacy_reference(resource, tmp_path):
    project, game, source = resource
    prepare(project, game, source)
    external = tmp_path / "external.wav"
    external.write_bytes(b"outside project")
    plan = json.loads(plan_path(project).read_text(encoding="utf-8"))
    plan["assets"] = [{"id": "external", "source": str(external)}]
    plan_path(project).write_text(json.dumps(plan), encoding="utf-8")
    remove_assets(project, {"assets": ["external"]})
    assert external.read_bytes() == b"outside project"
