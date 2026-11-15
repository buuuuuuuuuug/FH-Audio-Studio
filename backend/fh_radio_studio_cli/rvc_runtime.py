"""File-in/file-out adapter, executed only in the isolated RVC environment.

No application or game state is changed here. The parent owns task persistence,
process cancellation and adoption of the completed output.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

_cached_engine = None
_cached_key = None


def write_audio(output, rate, samples):
    import numpy as np
    import soundfile as sf

    audio = np.asarray(samples)
    if (
        not isinstance(rate, int)
        or not 8000 <= rate <= 192000
        or audio.ndim != 1
        or not len(audio)
        or not np.isfinite(audio).all()
    ):
        raise ValueError("RVC返回的音频为空或格式无效。")
    output = Path(output)
    temporary = output.with_suffix(".partial.wav")
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        sf.write(temporary, audio, rate, subtype="PCM_16")
        check, actual_rate = sf.read(temporary)
        if len(check) != len(audio) or actual_rate != rate:
            raise ValueError("RVC输出校验失败。")
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    return {"path": str(output), "sample_rate": rate, "duration": len(audio) / rate}


def convert(request):
    global _cached_engine, _cached_key
    source = Path(request["source_root"]).resolve(strict=True)
    if not (source / "infer/modules/vc/modules.py").is_file():
        raise ValueError("RVC推理源码缺失。")
    # Upstream Config parses argv; keep host CLI arguments out of it.
    sys.argv = [str(source / "fh-rvc-worker")]
    sys.path.insert(0, str(source))
    os.chdir(source)
    model = request["snapshot"]["model"]
    index = request["snapshot"].get("index")
    params = request["snapshot"]["parameters"]
    os.environ["weight_root"] = str(Path(model["absolute_path"]).parent)
    os.environ["TM_VOICE_ROOT"] = str(source)
    os.environ["rmvpe_root"] = str(source / "assets/rmvpe")
    os.environ["TM_ACCEL"] = "cuda" if request.get("device") == "cuda:0" else "cpu"
    # Imported voice checkpoints must never trigger the upstream pickle fallback.
    import infer.lib.safe_load as safe_load
    import torch

    # Some exported RVC checkpoints contain passive HParams metadata. Map only
    # this known container to our own inert class; never import checkpoint code.
    class HParams:
        pass

    def strict_load(path, map_location="cpu", **kwargs):
        with torch.serialization.safe_globals([(HParams, "utils.HParams")]):
            value = torch.load(path, map_location=map_location, weights_only=True)
        if Path(path).resolve() == Path(model["absolute_path"]).resolve():
            if (
                not isinstance(value, dict)
                or not isinstance(value.get("config"), (list, tuple))
                or "emb_g.weight" not in value.get("weight", {})
            ):
                raise ValueError(
                    "请选择导出的RVC v1/v2音色模型；GPT-SoVITS模型或训练存档不能用于音色转换。"
                )
        return value

    safe_load.safe_torch_load = strict_load
    # Fairseq's official feature checkpoint includes a passive vocabulary.
    # Allow its installed Dictionary only for that checksum-pinned base asset.
    import hashlib

    from fairseq import checkpoint_utils
    from fairseq.data.dictionary import Dictionary

    if not getattr(checkpoint_utils, "_fh_restricted", False):
        load_checkpoint = checkpoint_utils.load_checkpoint_to_cpu
        hubert = (source / "assets/hubert/hubert_base.pt").resolve()
        if (
            hashlib.sha256(hubert.read_bytes()).hexdigest()
            != "f54b40fd2802423a5643779c4861af1e9ee9c1564dc9d32f54f20b5ffba7db96"
        ):
            raise ValueError("特征模型校验失败，请修复推理引擎。")

        def load_feature(path, *args, **kwargs):
            if Path(path).resolve() == hubert:
                with torch.serialization.safe_globals([Dictionary]):
                    return load_checkpoint(path, *args, **kwargs)
            return load_checkpoint(path, *args, **kwargs)

        checkpoint_utils.load_checkpoint_to_cpu = load_feature
        checkpoint_utils._fh_restricted = True
    torch.set_num_threads(min(4, os.cpu_count() or 1))
    import faiss

    faiss.omp_set_num_threads(min(4, os.cpu_count() or 1))
    from configs.config import Config
    from infer.modules.vc.modules import VC

    config = Config()
    device = request.get("device", "cpu")
    if device not in ("cpu", "cuda:0"):
        raise ValueError("不支持的RVC推理设备。")
    if device.startswith("cuda") and not torch.cuda.is_available():
        raise ValueError("CUDA不可用。请在引擎设置中安装CUDA依赖，或切换CPU。")
    config.device = device
    config.is_half = device.startswith("cuda") and request.get("half", False)
    key = (model["id"], device, config.is_half)
    if _cached_key != key:
        if _cached_engine is not None:
            _cached_engine._release_models()
        _cached_engine = None
        _cached_key = None
        engine = VC(config)
        engine.get_vc(model["absolute_path"])
        if engine.version not in ("v1", "v2"):
            raise ValueError("当前只支持经过验证的RVC v1/v2模型。")
        _cached_engine, _cached_key = engine, key
    engine = _cached_engine
    if request.get("validate_only"):
        return {
            "version": engine.version,
            "sample_rate": engine.tgt_sr,
            "pitch_guidance": bool(engine.if_f0),
            "speakers": int(engine.cpt["config"][-3]),
        }
    if index:
        import faiss
        from infer.lib.faiss_io import read_index

        feature_index = read_index(index["absolute_path"])
        expected = 768 if engine.version == "v2" else 256
        if feature_index.d != expected or feature_index.ntotal < 8:
            raise ValueError(f"索引与音色模型不匹配：需要{expected}维有效RVC索引。")
        del feature_index
    speaker = params.get("speaker_id", 0)
    speaker_count = int(engine.cpt["config"][-3])
    if type(speaker) is not int or not 0 <= speaker < speaker_count:
        raise ValueError("RVC说话人编号无效。")

    def progress(stage, fraction):
        print("FH_RVC_PROGRESS " + json.dumps({"stage": stage, "fraction": fraction}), flush=True)

    detail, audio = engine.vc_single(
        speaker,
        request["input"],
        params["pitch"],
        None,
        params["f0_method"],
        index["absolute_path"] if index else "",
        "",
        params["index_rate"] if index else 0,
        params["filter_radius"],
        0,
        params["rms_mix_rate"],
        params["protect"],
        progress_cb=progress,
    )
    if audio is None or audio[0] is None or audio[1] is None:
        raise ValueError(f"RVC转换失败：{detail}")
    return {
        **write_audio(request["output"], int(audio[0]), audio[1]),
        "model_metadata": {
            "version": engine.version,
            "sample_rate": engine.tgt_sr,
            "speakers": speaker_count,
            "pitch_guidance": bool(engine.if_f0),
        },
    }


def main():
    # Parent supplies only application-owned request paths.
    if sys.argv[1] == "serve":
        for line in sys.stdin:
            handle(json.loads(line))
        return 0
    return handle(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")))


def handle(request):
    try:
        result = {"result": convert(request)}
    except Exception as error:
        result = {"error": str(error)}
    print("FH_RVC_RESULT " + json.dumps(result, ensure_ascii=False, allow_nan=False), flush=True)
    return 1 if "error" in result else 0


if __name__ == "__main__":
    raise SystemExit(main())
