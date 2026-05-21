"""Pin the single source of truth for forbidden shell metacharacters.

If a future contributor adds a check to one module and not the other,
the wizard-side validator (user config, sourced as bash) would drift
weaker than the preset-side parser. Identity-equality here proves both
import the exact same tuple object.
"""

from __future__ import annotations

from pa.paths import _FORBIDDEN_SUBSTRINGS as paths_forbidden
from pa.preset_loader import _FORBIDDEN_SUBSTRINGS as loader_forbidden


def test_forbidden_substrings_shared():
    assert paths_forbidden is loader_forbidden
