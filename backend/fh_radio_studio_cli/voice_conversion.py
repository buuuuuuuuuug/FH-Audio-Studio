"""RVC configuration and immutable imports, independent of speech presets.

Importing a checkpoint never deserializes it in the application environment.
The isolated inference adapter performs weight and architecture validation.
"""

from __future__ import annotations

import json
import math
import uuid
from pathlib import Path

from .common import CliError
from .file_lock import exclusive_file_lock
from .stingers import _copy_snapshot, _write, digest

DEFAULTS = {
    "pitch": 0,
    "speaker_id": 0,
    "f0_method": "rmvpe",
    "index_rate": 0.75,
    "protect": 0.33,
    "rms_mix_rate": 0.25,
    "filter_radius": 3,
}
LIMITS = {
    "pitch": (-24, 24, True),
    "speaker_id": (0, 1023, True),
    "index_rate": (0, 1, False),
    "protect": (0, 0.5, False),
    "rms_mix_rate": (0, 1, False),
    "filter_radius": (0, 7, True),
}


def parameters(value):
    if not isinstance(value, dict) or set(value) - set(DEFAULTS):
        raise CliError("RVC转换参数格式无效。")
    result = {**DEFAULTS, **value}
    for key, (low, high, integer) in LIMITS.items():
        number = result[key]
        if (
            isinstance(number, bool)
            or not isinstance(number, (int, float))
            or not math.isfinite(number)
            or not low <= number <= high
            or (integer and number != int(number))
        ):
            raise CliError(f"RVC参数 {key} 必须在 {low}～{high} 范围内。")
        result[key] = int(number) if integer else float(number)
    if result["f0_method"] not in ("rmvpe", "harvest", "pm"):
        raise CliError("不支持的RVC音高提取方法。")
    return result


class RvcCatalog:
    def __init__(self, home):
        self.home = Path(home).resolve()
        self.path = self.home / "settings.json"

    def read(self):
        if not self.path.exists():
            return {"schema_version": 1, "files": [], "parameters": dict(DEFAULTS)}
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            if data.get("schema_version") != 1 or not isinstance(data.get("files"), list):
                raise ValueError("unsupported settings")
            data["parameters"] = parameters(data.get("parameters", {}))
            return data
        except (ValueError, TypeError, AttributeError) as error:
            raise CliError("RVC设置文件损坏，已保留原文件。") from error

    def owned_file(self, record):
        path = self.home / record["path"]
        root = self.home / "imports"
        if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
            raise CliError("RVC文件路径超出托管目录。")
        return path

    def import_file(self, source, kind):
        source = Path(source).resolve()
        suffix = {"model": ".pth", "index": ".index"}.get(kind)
        if not suffix or not source.is_file() or source.suffix.lower() != suffix:
            raise CliError("请选择.pth音色模型或.index索引文件。")
        if not source.stat().st_size:
            raise CliError("不能导入空文件。")
        with exclusive_file_lock(self.home / "catalog.lock"):
            data = self.read()
            checksum = digest(source)
            existing = next((f for f in data["files"] if f["id"] == checksum), None)
            if existing:
                target = self.owned_file(existing)
                if not target.exists():
                    _copy_snapshot(source, target)
                elif digest(target) != checksum:
                    raise CliError("已导入文件校验失败，未覆盖，请移除损坏副本后重试。")
                return existing
            target = self.home / "imports" / checksum / source.name
            _copy_snapshot(source, target)
            if digest(target) != checksum:
                raise CliError("导入时源文件发生变化，请重试。")
            record = {
                "id": checksum,
                "kind": kind,
                "filename": source.name,
                "path": target.relative_to(self.home).as_posix(),
                "size": target.stat().st_size,
                "validation": "pending",
            }
            data["files"].append(record)
            _write(self.path, data)
            return record

    def select_model(self, model_id, index_id=None):
        with exclusive_file_lock(self.home / "catalog.lock"):
            data = self.read()
            for identity, kind in ((model_id, "model"), (index_id, "index")):
                if identity is None and kind == "index":
                    continue
                record = next(
                    (f for f in data["files"] if f["id"] == identity and f["kind"] == kind), None
                )
                if record is None or not self.owned_file(record).is_file():
                    raise CliError("RVC音色或索引不存在，请重新导入。")
            data["selection"] = {"model_id": model_id, "index_id": index_id}
            _write(self.path, data)
            return data

    def save_parameters(self, value):
        checked = parameters(value)
        with exclusive_file_lock(self.home / "catalog.lock"):
            data = self.read()
            data["parameters"] = checked
            _write(self.path, data)
            return data

    @staticmethod
    def configuration(data):
        return {
            "selection": dict(data.get("selection", {})),
            "parameters": parameters(data.get("parameters", {})),
            "runtime": dict(data.get("runtime", {"device": "cpu"})),
        }

    def preset_state(self, data=None):
        data = self.read() if data is None else data
        selected = next(
            (p for p in data.get("presets", []) if p["id"] == data.get("selected_preset_id")), None
        )
        return {
            "presets": data.get("presets", []),
            "selected_preset_id": selected["id"] if selected else None,
            "preset_dirty": bool(
                selected and selected["configuration"] != self.configuration(data)
            ),
        }

    def _validate_configuration(self, data, config):
        for kind in ("model", "index"):
            identity = config["selection"].get(f"{kind}_id")
            if identity is None and kind == "index":
                continue
            record = next(
                (f for f in data["files"] if f["id"] == identity and f["kind"] == kind), None
            )
            if record is None or not self.owned_file(record).is_file():
                raise CliError("预设中的 RVC 音色或索引不存在，请重新导入。")
        if config["runtime"].get("device") not in ("cpu", "cuda:0"):
            raise CliError("无效的推理设备。")
        parameters(config["parameters"])

    def save_preset(self, name, preset_id=None):
        name = str(name or "").strip()
        if not name or len(name) > 100:
            raise CliError("请输入 1～100 字的预设名称。")
        with exclusive_file_lock(self.home / "catalog.lock"):
            data = self.read()
            presets = data.setdefault("presets", [])
            if preset_id and not any(p["id"] == preset_id for p in presets):
                raise CliError("RVC 预设不存在。")
            if any(
                p["name"].casefold() == name.casefold() and p["id"] != preset_id for p in presets
            ):
                raise CliError("预设名称已存在。")
            config = self.configuration(data)
            self._validate_configuration(data, config)
            record = {"id": preset_id or uuid.uuid4().hex, "name": name, "configuration": config}
            data["presets"] = [p for p in presets if p["id"] != record["id"]] + [record]
            data["selected_preset_id"] = record["id"]
            _write(self.path, data)
            return record

    def select_preset(self, preset_id):
        with exclusive_file_lock(self.home / "catalog.lock"):
            data = self.read()
            if preset_id:
                preset = next((p for p in data.get("presets", []) if p["id"] == preset_id), None)
                if preset is None:
                    raise CliError("RVC 预设不存在。")
                config = self.configuration(preset["configuration"])
                self._validate_configuration(data, config)
                data.update(config)
            data["selected_preset_id"] = preset_id or None
            _write(self.path, data)
            return data

    def delete_preset(self, preset_id):
        with exclusive_file_lock(self.home / "catalog.lock"):
            data = self.read()
            data["presets"] = [p for p in data.get("presets", []) if p["id"] != preset_id]
            if data.get("selected_preset_id") == preset_id:
                data["selected_preset_id"] = None
            _write(self.path, data)
            return data

    def snapshot(self):
        """Freeze verified file identities and effective parameters at submission."""
        data = self.read()
        selection = data.get("selection", {})
        result = {"parameters": dict(data["parameters"])}
        for kind in ("model", "index"):
            identity = selection.get(f"{kind}_id")
            if identity is None and kind == "index":
                result["parameters"]["index_rate"] = 0.0
                result["index"] = None
                continue
            record = next((f for f in data["files"] if f["id"] == identity), None)
            if record is None or record["kind"] != kind:
                raise CliError("请先选择有效的RVC音色模型。")
            path = self.owned_file(record)
            if not path.is_file() or digest(path) != identity:
                raise CliError(f"RVC文件丢失或发生变化：{record['filename']}")
            result[kind] = {**record, "absolute_path": str(path)}
        return result
