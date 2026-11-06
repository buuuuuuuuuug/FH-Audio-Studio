"""Language choices describe tool content; never install language support files."""


def is_language_support_file(path):
    value = str(path or "").replace("\\", "/").lower().strip("/")
    return (
        value.split("/")[-1] in {"userpreferredlang", "userpreferredaudiolang"}
        or "stripped/stringtables/" in value
    )
