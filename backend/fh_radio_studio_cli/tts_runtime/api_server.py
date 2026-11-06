"""Launch official api_v2 with this application's owned runtime data paths.

Upstream's portable initializer assumes its own bundled runtime/nltk_data.
Initialize it once, then restore our prepared data root before it imports NLTK.
No inference, API routes or model logic is reimplemented here.
"""

import os
import runpy
import sys
from pathlib import Path


def main():
    home, source = map(Path, sys.argv[1:3])
    arguments = sys.argv[3:]
    sys.path.insert(0, str(source))
    from tools.portable_runtime import activate

    activate(change_cwd=True)
    os.environ["NLTK_DATA"] = str(home / "nltk_data")
    sys.argv = [str(source / "api_v2.py"), *arguments]
    runpy.run_path(sys.argv[0], run_name="__main__")


if __name__ == "__main__":
    main()
