import json
from types import SimpleNamespace

from backend.fh_radio_studio_cli.baseline import load_baseline_md5s
from backend.fh_radio_studio_cli.common import md5_file
from backend.fh_radio_studio_cli.integrity import _manifest_md5s_by_path
from backend.fh_radio_studio_cli.package import (
    collect_package_deploy_files,
    complete_package_from_baseline,
    package_language_settings,
)


def test_selected_languages_do_not_require_or_copy_a_language_backup(tmp_path):
    args = SimpleNamespace(
        source="CHS", target="JP", source_string_tables_dir=str(tmp_path / "missing")
    )
    output = tmp_path / "package/media/Stripped/StringTables"
    assert package_language_settings(args, tmp_path, output) is None
    assert not output.exists()


def test_old_package_language_archives_are_never_deployable(tmp_path):
    bank = tmp_path / "media/audio/FMODBanks/VO_Test_JP.assets.bank"
    bank.parent.mkdir(parents=True)
    bank.write_bytes(b"replacement bank")
    table = tmp_path / "media/Stripped/StringTables/JP.zip"
    table.parent.mkdir(parents=True)
    table.write_bytes(b"obsolete whole language archive")
    files = collect_package_deploy_files(tmp_path)
    assert [f["source"] for f in files] == [bank]


def test_old_language_backup_hashes_do_not_create_update_conflicts(tmp_path):
    manifest = tmp_path / "baseline_manifest.json"
    language = "media/Stripped/StringTables/JP.zip"
    bank = "media/audio/FMODBanks/VO_Test_JP.assets.bank"
    manifest.write_text(
        json.dumps(
            {
                "files": [
                    {"install_relative_path": language, "md5": "old-language"},
                    {"install_relative_path": bank, "md5": "required-original-audio"},
                ]
            }
        ),
        encoding="utf-8",
    )
    for hashes in (load_baseline_md5s(str(manifest)), _manifest_md5s_by_path(manifest)):
        assert language not in hashes
        assert hashes[bank] == "required-original-audio"


def test_legacy_backup_completion_never_copies_or_requires_language_archives(tmp_path):
    backup = tmp_path / "media/audio/FMODBanks/VO_Test_JP.assets.bank"
    backup.parent.mkdir(parents=True)
    backup.write_bytes(b"required original bank")
    manifest = tmp_path / "baseline_manifest.json"
    manifest.write_text(
        json.dumps(
            {
                "files": [
                    {
                        "scope": "string_table",
                        "install_relative_path": "media/Stripped/StringTables/JP.zip",
                        "backup_path": str(tmp_path / "missing-old.zip"),
                        "md5": "old",
                    },
                    {
                        "install_relative_path": "media/audio/FMODBanks/VO_Test_JP.assets.bank",
                        "backup_path": str(backup),
                        "md5": md5_file(backup),
                    },
                ]
            }
        ),
        encoding="utf-8",
    )
    package = tmp_path / "package"
    result = complete_package_from_baseline(package, str(manifest))
    assert result["baseline_files"] == 1
    assert (
        package / "media/audio/FMODBanks/VO_Test_JP.assets.bank"
    ).read_bytes() == backup.read_bytes()
    assert not (package / "media/Stripped").exists()
