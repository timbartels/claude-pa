#!/usr/bin/env python3
"""SessionStart hook entry point. See ``pa.vault_context`` for behavior."""

from __future__ import annotations

import os
import sys
from pathlib import Path

# Resolve lib/ from this script's location. CLAUDE_PLUGIN_ROOT is set by
# Claude Code when invoking hooks, but fall back to the static layout
# (hooks/scripts/foo.py → ../../lib) for local-test invocations.
_root = os.environ.get("CLAUDE_PLUGIN_ROOT")
_lib = Path(_root) / "lib" if _root else Path(__file__).resolve().parents[2] / "lib"
sys.path.insert(0, str(_lib))

from pa.vault_context import main  # noqa: E402

if __name__ == "__main__":
    main()
