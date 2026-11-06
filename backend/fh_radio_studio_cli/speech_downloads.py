"""Install-time mirrors. Pinned versions and wheel hashes stay unchanged."""

from urllib.parse import urlsplit

from .common import CliError

OFFICIAL = {
    "hf": "https://huggingface.co",
    "pypi": "https://pypi.org/simple",
    "torch": "https://download.pytorch.org/whl/cu126",
    "github": "",
}
DOMESTIC = {
    "hf": "https://hf-mirror.com",
    "pypi": "https://pypi.tuna.tsinghua.edu.cn/simple",
    "torch": "https://mirror.sjtu.edu.cn/pytorch-wheels/cu126",
    "github": "",
}
PYPI_MIRRORS = (
    DOMESTIC["pypi"],
    "https://mirrors.aliyun.com/pypi/simple",
    "https://repo.huaweicloud.com/repository/pypi/simple",
    "https://mirrors.ustc.edu.cn/pypi/simple",
    "https://mirrors.bfsu.edu.cn/pypi/web/simple",
    OFFICIAL["pypi"],
)
TORCH_MIRRORS = (
    DOMESTIC["torch"],
    "https://mirrors.nju.edu.cn/pytorch/whl/cu126",
    OFFICIAL["torch"],
)


def download_settings(value=None):
    value = value or {}
    profile = value.get("profile", "official")
    if profile not in ("official", "domestic", "custom"):
        raise CliError("请选择有效的下载源。")
    result = dict(DOMESTIC if profile == "domestic" else OFFICIAL)
    if profile == "domestic":
        for key, choices in (
            ("pypi", PYPI_MIRRORS),
            ("torch", TORCH_MIRRORS),
            ("hf", (DOMESTIC["hf"], OFFICIAL["hf"])),
        ):
            if value.get(key):
                address = str(value[key]).strip().rstrip("/")
                if address not in choices:
                    raise CliError("请选择内置镜像，或切换到自定义下载源。")
                result[key] = address
    if profile == "custom":
        for key in result:
            result[key] = str(value.get(key, result[key])).strip().rstrip("/")
    for key, address in result.items():
        if key == "github" and not address:
            continue
        parsed = urlsplit(address)
        if any(c in address for c in (chr(34), chr(92), chr(32), chr(10), chr(13), chr(9))):
            raise CliError("下载源不能包含空白或引号。")
        if (
            parsed.scheme != "https"
            or not parsed.netloc
            or parsed.username
            or parsed.password
            or parsed.query
            or parsed.fragment
        ):
            raise CliError("下载源请使用不含账号和查询参数的 HTTPS 地址。")
    return {"profile": profile, **result}


def model_url(url, settings):
    if url.startswith("https://huggingface.co/"):
        return settings["hf"] + url[len("https://huggingface.co") :]
    if settings["github"] and urlsplit(url).hostname in (
        "github.com",
        "raw.githubusercontent.com",
        "codeload.github.com",
    ):
        return settings["github"] + "/" + url
    return url


def download_candidates(url, settings):
    """Prefer the selected source; retain official, verified alternate routes."""
    values = [model_url(url, settings), url]
    if (
        url
        == "https://github.com/r9y9/open_jtalk/releases/download/v1.11.1/open_jtalk_dic_utf_8-1.11.tar.gz"
    ):
        values.append(
            "https://downloads.sourceforge.net/project/open-jtalk/Dictionary/open_jtalk_dic-1.11/open_jtalk_dic_utf_8-1.11.tar.gz"
        )
    if url.startswith("https://raw.githubusercontent.com/nltk/nltk_data/gh-pages/"):
        values.append(
            url.replace(
                "https://raw.githubusercontent.com/nltk/nltk_data/gh-pages/",
                "https://github.com/nltk/nltk_data/raw/refs/heads/gh-pages/",
            )
        )
    return list(dict.fromkeys(values))


def mirrored_runtime(project, lock, settings):
    for original in (
        "https://download.pytorch.org/whl/cu126",
        "https://download-r2.pytorch.org/whl/cu126",
    ):
        project = project.replace(original, settings["torch"])
        lock = lock.replace(original, settings["torch"])
    if settings["pypi"] != OFFICIAL["pypi"]:
        project += (
            '\n[[tool.uv.index]]\nname = "pypi"\ndefault = true\nurl = "' + settings["pypi"] + '"\n'
        )
        lock = lock.replace(OFFICIAL["pypi"], settings["pypi"])
        # These mirrors retain PyPI's package paths and the original hashes.
        if settings["pypi"].endswith("/simple"):
            packages = settings["pypi"][: -len("/simple")] + "/packages/"
            lock = lock.replace("https://files.pythonhosted.org/packages/", packages)
    return project, lock
