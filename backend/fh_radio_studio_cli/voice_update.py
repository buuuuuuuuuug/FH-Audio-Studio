"""Refresh game originals without assigning edits to a different sound index."""

import copy
import json
import time
from pathlib import Path

from .common import md5_file
from .deployment_paths import contained_game_path
from .stingers import _write, digest, local_file


def remap_edits(edits, mapping):
    return {mapping[str(i)]: copy.deepcopy(edit) for i, edit in edits.items() if str(i) in mapping}


def synchronize(project, game, *, verify=False, **languages):
    from .voices import load_plan, plan_path, prepare

    plan = load_plan(project)
    record = project / ".fh-radio-studio/last_applied_package_manifest.json"
    owned = json.loads(record.read_text(encoding="utf-8")) if record.is_file() else {}
    owned = {i.get("install_relative_path"): i.get("md5") for i in owned.get("package_files", [])}
    changed = False
    for identity, old in list(plan["banks"].items()):
        if old.get("custom"):
            continue
        source = contained_game_path(game, old["relative_path"])
        if not source.is_file():
            old["update_error"] = "游戏中的原文件已移除；原备份与制作保留，暂不可构建此资源。"
            changed = True
            continue
        stat = source.stat()
        signature = [stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns]
        if not verify and not old.get("update_error") and old.get("game_signature") == signature:
            continue
        sha = digest(source)
        if sha == old["sha256"] or md5_file(source) == owned.get(old["relative_path"]):
            if not verify:
                old["game_signature"] = signature
                changed = True
            old.pop("update_error", None)
            continue
        catalog = project / f"analysis/voices/catalog/{old['sha256']}.json"
        if not catalog.is_file():
            old["update_error"] = (
                "游戏原文件已变化，旧条目清单缺失，不能安全迁移替换；原备份与制作已保留。"
            )
            changed = True
            continue
        previous = json.loads(catalog.read_text(encoding="utf-8"))
        from .voice_bank import read_bank

        try:
            read_bank(source.read_bytes())
        except Exception:
            old["update_error"] = (
                "游戏资源已更新为暂不支持的格式；保留旧备份与制作，停止重构和写入此文件。"
            )
            changed = True
            continue
        history = (
            project
            / f".fh-radio-studio/voices/history/{identity}-{old['sha256']}-{time.time_ns()}.json"
        )
        _write(history, {"bank": old, "entries": previous})
        # prepare adopts only the base media file, never our installed overlay.
        fresh = prepare(project, game, source, _adopt_current=True, **languages)
        bank, entries = fresh["bank"], fresh["entries"]

        def identities(path, items):
            try:
                lookup = read_bank(path.read_bytes())[3]
            except Exception:
                lookup = {}
            return {
                str(e["index"]): tuple(sorted(k for k, v in lookup.items() if v == e["index"]))
                or (e["name"] if not e["name"].startswith("条目 ") else None)
                for e in items
            }

        old_ids = identities(local_file(project, old["source"]), previous)
        new_ids = identities(source, entries)
        names = {}
        old_names = {}
        for e in entries:
            names.setdefault(new_ids[str(e["index"])], []).append(str(e["index"]))
        for e in previous:
            old_names.setdefault(old_ids[str(e["index"])], []).append(str(e["index"]))
        mapping = {
            index: names[key][0]
            for index, key in old_ids.items()
            if key is not None and len(names.get(key, [])) == 1 and len(old_names[key]) == 1
        }
        bank["replacements"] = remap_edits(old["replacements"], mapping)
        conflicts = [i for i in old["replacements"] if str(i) not in mapping]
        bank["update_conflicts"] = conflicts
        bank["update_history"] = [
            *old.get("update_history", []),
            {
                "from_sha256": old["sha256"],
                "to_sha256": bank["sha256"],
                "mapping": mapping,
                "archive": str(history),
                "unmatched": conflicts,
            },
        ]
        bank["game_signature"] = signature
        bank["update_notice"] = (
            f"游戏资源已更新，按名称迁移 {len(bank['replacements'])} 条替换；未匹配 {len(conflicts)} 条，旧制作已存档。"
        )
        plan["banks"][identity] = bank
        # Drafts on disk follow the same sound identity mapping. Archive the
        # complete old draft before changing indices; unmatched edits survive there.
        draft_path = project / "analysis/voices/draft.json"
        if draft_path.is_file():
            draft = json.loads(draft_path.read_text(encoding="utf-8"))
            _write(history.with_suffix(".draft.json"), draft)
            for field in ("edits", "saved"):
                if identity in draft.get(field, {}):
                    before = draft[field][identity]
                    if any(str(i) not in mapping for i in before):
                        bank["update_conflicts"] = sorted(
                            set(bank["update_conflicts"])
                            | {str(i) for i in before if str(i) not in mapping}
                        )
                    draft[field][identity] = remap_edits(before, mapping)
            _write(draft_path, draft)
        changed = True
    if changed:
        _write(plan_path(project), plan)
    return plan
