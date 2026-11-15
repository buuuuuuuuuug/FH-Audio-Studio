"""RVC mirrors preserve the pinned CPU/CUDA versions and wheel hashes."""

from .common import CliError
from .speech_downloads import download_settings, mirrored_runtime

TORCH_OFFICIAL = "https://download.pytorch.org/whl"
TORCH_MIRROR = "https://mirror.sjtu.edu.cn/pytorch-wheels"


def rvc_download_settings(value=None):
    value = value or {}
    result = download_settings({k: v for k, v in value.items() if k != "torch"})
    default = TORCH_MIRROR if result["profile"] == "domestic" else TORCH_OFFICIAL
    address = str(value.get("rvc_torch") or default).strip().rstrip("/")
    if result["profile"] == "official":
        address = TORCH_OFFICIAL
    elif result["profile"] != "custom" and address not in (TORCH_MIRROR, TORCH_OFFICIAL):
        raise CliError("请选择内置 PyTorch 镜像，或切换到自定义下载源。")
    # Reuse HTTPS/credential/whitespace validation, without the GPT CUDA version.
    download_settings({"profile": "custom", "torch": address})
    return {**result, "rvc_torch": address}


def rvc_mirrored_runtime(project, lock, sources):
    # Common PyPI mirrors retain the package paths and original SHA-256 values.
    project, lock = mirrored_runtime(project, lock, sources)
    for original in (TORCH_OFFICIAL, "https://download-r2.pytorch.org/whl"):
        project = project.replace(original + "/", sources["rvc_torch"] + "/")
        lock = lock.replace(original + "/", sources["rvc_torch"] + "/")
    return project, lock
