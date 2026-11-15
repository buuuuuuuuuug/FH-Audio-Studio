import pytest

from backend.fh_radio_studio_cli.common import CliError
from backend.fh_radio_studio_cli.voice_conversion import DEFAULTS, RvcCatalog, parameters


@pytest.mark.parametrize("value", [True, float("nan"), float("inf"), -25, 25, 0.5])
def test_pitch_rejects_invalid_values(value):
    with pytest.raises(CliError):
        parameters({"pitch": value})


def test_import_preserves_filename_deduplicates_and_recovers_missing_copy(tmp_path):
    source = tmp_path / "爱丽丝.pth"
    source.write_bytes(b"checkpoint-placeholder")
    catalog = RvcCatalog(tmp_path / "engine")
    record = catalog.import_file(source, "model")
    assert record["filename"] == source.name
    assert record["validation"] == "pending"
    assert catalog.import_file(source, "model") == record
    catalog.owned_file(record).unlink()
    assert catalog.import_file(source, "model") == record
    assert catalog.owned_file(record).read_bytes() == source.read_bytes()
    assert len(catalog.read()["files"]) == 1


def test_model_selection_preserves_parameters_and_snapshot_is_independent(tmp_path):
    source = tmp_path / "voice.pth"
    source.write_bytes(b"checkpoint-placeholder")
    catalog = RvcCatalog(tmp_path / "engine")
    record = catalog.import_file(source, "model")
    catalog.save_parameters({"pitch": 12})
    catalog.select_model(record["id"])
    snapshot = catalog.snapshot()
    assert snapshot["parameters"]["pitch"] == 12
    assert snapshot["parameters"]["index_rate"] == 0
    assert catalog.read()["parameters"]["index_rate"] == DEFAULTS["index_rate"]
    catalog.save_parameters({"pitch": -12})
    assert snapshot["parameters"]["pitch"] == 12


def test_changed_model_cannot_be_submitted(tmp_path):
    source = tmp_path / "voice.pth"
    source.write_bytes(b"checkpoint-placeholder")
    catalog = RvcCatalog(tmp_path / "engine")
    record = catalog.import_file(source, "model")
    catalog.select_model(record["id"])
    catalog.owned_file(record).write_bytes(b"changed")
    with pytest.raises(CliError, match="发生变化"):
        catalog.snapshot()


def test_corrupt_settings_are_preserved(tmp_path):
    catalog = RvcCatalog(tmp_path)
    catalog.path.write_text("broken", encoding="utf-8")
    with pytest.raises(CliError, match="损坏"):
        catalog.read()
    assert catalog.path.read_text(encoding="utf-8") == "broken"


def test_presets_restore_voice_index_device_parameters_and_keep_current_on_delete(tmp_path):
    import json

    model, index = tmp_path / "voice.pth", tmp_path / "voice.index"
    model.write_bytes(b"model")
    index.write_bytes(b"index")
    catalog = RvcCatalog(tmp_path / "engine")
    voice = catalog.import_file(model, "model")
    lookup = catalog.import_file(index, "index")
    catalog.select_model(voice["id"], lookup["id"])
    catalog.save_parameters({"pitch": 3, "protect": 0.2})
    data = catalog.read()
    data["runtime"] = {"device": "cuda:0"}
    catalog.path.write_text(json.dumps(data), encoding="utf-8")
    preset = catalog.save_preset("测试音色")
    assert not catalog.preset_state()["preset_dirty"]
    catalog.save_parameters({"pitch": -4})
    assert catalog.preset_state()["preset_dirty"]
    restored = RvcCatalog(catalog.home).select_preset(preset["id"])
    assert restored["parameters"]["pitch"] == 3
    assert restored["selection"]["index_id"] == lookup["id"]
    assert restored["runtime"]["device"] == "cuda:0"
    assert not catalog.preset_state()["preset_dirty"]
    catalog.delete_preset(preset["id"])
    assert catalog.read()["parameters"]["pitch"] == 3
    assert catalog.owned_file(voice).is_file() and catalog.owned_file(lookup).is_file()


def test_preset_names_and_missing_files_cannot_overwrite_current_configuration(tmp_path):
    model = tmp_path / "voice.pth"
    model.write_bytes(b"model")
    catalog = RvcCatalog(tmp_path / "engine")
    voice = catalog.import_file(model, "model")
    catalog.select_model(voice["id"])
    preset = catalog.save_preset("Voice")
    with pytest.raises(CliError, match="名称已存在"):
        catalog.save_preset("voice")
    catalog.save_parameters({"pitch": 7})
    assert catalog.save_preset("Voice", preset["id"])["id"] == preset["id"]
    catalog.save_parameters({"pitch": -3})
    catalog.owned_file(voice).unlink()
    before = catalog.path.read_bytes()
    with pytest.raises(CliError, match="不存在"):
        catalog.select_preset(preset["id"])
    assert catalog.path.read_bytes() == before


def test_runtime_publishes_only_complete_valid_audio(tmp_path):
    import numpy as np
    import soundfile as sf

    from backend.fh_radio_studio_cli.rvc_runtime import write_audio

    output = tmp_path / "转换结果.wav"
    result = write_audio(output, 40000, np.zeros(4000, dtype=np.float32))
    assert result["duration"] == 0.1
    assert sf.info(output).frames == 4000
    previous = output.read_bytes()
    with pytest.raises(ValueError):
        write_audio(output, 40000, np.array([float("nan")]))
    assert output.read_bytes() == previous
    assert not output.with_suffix(".partial.wav").exists()
