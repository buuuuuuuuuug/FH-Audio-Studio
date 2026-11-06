"""Input fingerprints keep old prepared packages from undoing game updates."""

from pathlib import Path

from .common import CliError, md5_file
from .deployment_paths import contained_game_path


def audio_signature(game):
    return [
        (p.relative_to(game).as_posix(), p.stat().st_size, p.stat().st_mtime_ns)
        for layer in ("media", "mediapc")
        for p in sorted((game / layer / "audio").rglob("*"))
        if p.is_file() and p.suffix.lower() in {".xml", ".bank"}
    ]


def package_inputs(game, files):
    result = []
    for item in files:
        relative = str(item["install_relative_path"])
        if not relative.startswith("media/"):
            continue
        result.append(
            {"relative_path": relative, "base_md5": md5_file(contained_game_path(game, relative))}
        )
    return result


def stamp_package_inputs(game, package):
    import json

    from .package import collect_package_deploy_files
    from .project_json_guard import write_project_json

    path = Path(package) / "fh_radio_studio_package_manifest.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    data["game_inputs"] = package_inputs(Path(game), collect_package_deploy_files(Path(package)))
    write_project_json(path, data)


def validate_package_inputs(manifest, game, files):
    selected = {str(item["install_relative_path"]) for item in files}
    sources = {str(item["install_relative_path"]): item["source"] for item in files}
    for item in manifest.get("game_inputs", []):
        relative = item["relative_path"]
        if relative not in selected:
            continue
        current = md5_file(contained_game_path(game, relative))
        if current != item["base_md5"] and current != md5_file(Path(sources[relative])):
            raise CliError(
                f"{Path(relative).name} 的游戏原文件在构建后已更新。制作内容和旧准备包均已保留，请重新构建后再写入。"
            )
    # Older prepared packages have no original-input fingerprints. Do not let
    # a different known game build silently reuse that unverified package.
    if "game_inputs" not in manifest and manifest.get("game_version_id"):
        from .baseline import baseline_version_id
        from .game import steam_game_version

        if baseline_version_id(steam_game_version(game)) != manifest["game_version_id"]:
            raise CliError("此准备包来自旧游戏版本且缺少原文件指纹。请重新构建；现有制作已保留。")


def synchronize_stingers(project, game):
    """Sound-name keyed assignments survive an official bank/XML refresh."""
    import json
    import time

    from .project_refs import project_path_or_absolute
    from .stingers import _copy_snapshot, _write, digest, load_plan, local_file, plan_path

    plan = load_plan(project)
    record = project / ".fh-radio-studio/last_applied_package_manifest.json"
    applied = json.loads(record.read_text(encoding="utf-8")) if record.is_file() else {}
    owned = {i.get("install_relative_path"): i.get("md5") for i in applied.get("package_files", [])}
    changed = False
    for key, baseline in plan["baselines"].items():
        paths = [
            game / f"media/audio/FMODBanks/{baseline['bank_name']}",
            game / f"media/audio/RadioInfo_{baseline['locale']}.xml",
        ]
        if not all(p.is_file() for p in paths):
            baseline["update_error"] = (
                "更新后的游戏缺少台呼原文件，保留原制作，请补齐官方文件后重试。"
            )
            changed = True
            continue
        signature = [[p.stat().st_size, p.stat().st_mtime_ns, p.stat().st_ctime_ns] for p in paths]
        if not baseline.get("update_error") and baseline.get("game_signature") == signature:
            continue
        updates = []
        for path, ref, checksum in zip(paths, ("bank_ref", "xml_ref"), ("sha256", "xml_sha256")):
            sha = digest(path)
            relative = path.relative_to(game).as_posix()
            if sha != baseline[checksum] and md5_file(path) != owned.get(relative):
                updates.append((path, ref, checksum, sha))
        if updates:
            # An XML may change songs while preserving the stinger list. Keep
            # all assignments by SoundName; validation rejects removed slots.
            history = (
                project
                / f".fh-radio-studio/stingers/history/{key.replace(':', '-')}-{baseline['sha256']}-{time.time_ns()}.json"
            )
            if not history.exists():
                _write(
                    history,
                    {
                        "baseline": baseline,
                        "assignments": {
                            k: v for k, v in plan["assignments"].items() if k.startswith(key + ":")
                        },
                    },
                )
            for path, ref, checksum, sha in updates:
                target = project / ".fh-radio-studio/stingers/baselines" / (sha + path.suffix)
                _copy_snapshot(path, target)
                baseline[ref] = project_path_or_absolute(project, target)
                baseline[checksum] = sha
            baseline["update_notice"] = "游戏台呼原文件已更新；素材与按台呼名称关联的分配已保留。"
        baseline["game_signature"] = signature
        baseline.pop("update_error", None)
        changed = True
    if changed:
        _write(plan_path(project), plan)
    return plan
