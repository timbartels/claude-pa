#!/usr/bin/env python3
"""Multi-event PA state-file hook entry point. See ``pa.state_update``."""

from __future__ import annotations

import os
import sys
from pathlib import Path

_root = os.environ.get("CLAUDE_PLUGIN_ROOT")
_lib = Path(_root) / "lib" if _root else Path(__file__).resolve().parents[2] / "lib"
sys.path.insert(0, str(_lib))

from pa.state_update import main  # noqa: E402

if __name__ == "__main__":
    main()
