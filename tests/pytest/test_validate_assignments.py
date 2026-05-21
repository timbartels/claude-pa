"""Tests for pa.paths.validate_assignments.

Adversarial matrix mirrors test_preset_loader's style. Snapshot tests
freeze the exact error-message bytes so the bash↔Python contract
documented in docs/plans/2026-05-21-feat-pa-init-three-modes-plan.md
cannot drift silently.
"""

from __future__ import annotations

import pytest

from pa.paths import validate_assignments

REQUIRED_PAIR = [
    "PA_VAULT=/tmp",
    "PA_PROJECTS_DIR=/tmp",
]


def test_happy_path_no_source_labels():
    out, errs = validate_assignments(REQUIRED_PAIR)
    assert errs == []
    assert "PA_VAULT=/tmp" in out
    assert "PA_PROJECTS_DIR=/tmp" in out


def test_source_labels_round_trip():
    """Trailing `\\t# (source)` labels survive validation."""
    out, errs = validate_assignments(
        [
            "PA_VAULT=/tmp\t# (auto-detect)",
            "PA_PROJECTS_DIR=/tmp\t# (--set)",
        ]
    )
    assert errs == []
    assert out[0].endswith("# (auto-detect)")
    assert out[1].endswith("# (--set)")


def test_quoted_value_with_unicode_ok():
    """Double-quoted bodies allow Unicode (matches preset_loader)."""
    out, errs = validate_assignments(
        [*REQUIRED_PAIR, 'PA_MAIN_TITLE="MAIN · TEST"']
    )
    assert errs == []
    assert any("MAIN · TEST" in line for line in out)


def test_blank_and_comment_lines_skipped():
    out, errs = validate_assignments(
        ["", "# top comment", "PA_VAULT=/tmp", "  ", "PA_PROJECTS_DIR=/tmp"]
    )
    assert errs == []
    assert len(out) == 2


@pytest.mark.parametrize(
    "evil",
    [
        "PA_VAULT=$(whoami)",
        "PA_VAULT=`whoami`",
        "PA_VAULT=${HOME}/x",
        "PA_VAULT=foo|bar",
        "PA_VAULT=a;b",
        "PA_VAULT=a&&b",
        "PA_VAULT=a>file",
        "PA_VAULT=a\\nb",  # backslash escape
    ],
)
def test_metachar_rejected(evil: str):
    out, errs = validate_assignments([evil, "PA_PROJECTS_DIR=/tmp"])
    assert out == []
    assert errs  # at least one error
    assert any("PA_VAULT" in e or "unparseable" in e for e in errs)


def test_unknown_key_rejected():
    out, errs = validate_assignments([*REQUIRED_PAIR, "PA_BOGUS=x"])
    assert out == []
    assert any("PA_BOGUS" in e and "unknown key" in e for e in errs)


def test_unparseable_line_reported():
    out, errs = validate_assignments(["not an assignment"])
    assert out == []
    assert any("unparseable" in e for e in errs)


def test_missing_required_PA_VAULT():
    out, errs = validate_assignments(["PA_PROJECTS_DIR=/tmp"])
    assert out == []
    assert any("PA_VAULT" in e and "missing required key" in e for e in errs)


def test_missing_required_PA_PROJECTS_DIR():
    out, errs = validate_assignments(["PA_VAULT=/tmp"])
    assert out == []
    assert any(
        "PA_PROJECTS_DIR" in e and "missing required key" in e for e in errs
    )


def test_bad_terminal_backend():
    out, errs = validate_assignments(
        [*REQUIRED_PAIR, "PA_TERMINAL_BACKEND=zellij"]
    )
    assert out == []
    assert any("PA_TERMINAL_BACKEND" in e and "zellij" in e for e in errs)


def test_dashboard_interval_not_int():
    out, errs = validate_assignments(
        [*REQUIRED_PAIR, "PA_DASHBOARD_INTERVAL=banana"]
    )
    assert out == []
    assert any(
        "PA_DASHBOARD_INTERVAL" in e and "not an integer" in e for e in errs
    )


def test_dashboard_interval_below_one():
    out, errs = validate_assignments(
        [*REQUIRED_PAIR, "PA_DASHBOARD_INTERVAL=0"]
    )
    assert out == []
    assert any("PA_DASHBOARD_INTERVAL" in e and ">= 1" in e for e in errs)


def test_status_shipped_not_in_status_values():
    out, errs = validate_assignments(
        [*REQUIRED_PAIR, 'PA_STATUS_VALUES="brainstorming,shipped"', "PA_STATUS_SHIPPED=NONESUCH"]
    )
    assert out == []
    assert any(
        "PA_STATUS_SHIPPED" in e and "not in" in e for e in errs
    )


# Snapshot tests: freeze exact error-message bytes so the wizard can
# pattern-match in bats without breakage as the validator evolves.
def test_error_snapshot_unknown_key():
    _, errs = validate_assignments([*REQUIRED_PAIR, "PA_BOGUS=x"])
    assert any(
        e.startswith("pa init: PA_BOGUS: unknown key (allowed:") for e in errs
    )


def test_error_snapshot_forbidden_metachar():
    _, errs = validate_assignments(["PA_VAULT=`whoami`", "PA_PROJECTS_DIR=/tmp"])
    # The regex catches this as unparseable before it reaches the
    # substring check (backticks aren't in the strict bare char class).
    assert any(
        e.startswith("pa init: <unparseable>: cannot parse") for e in errs
    )


def test_error_snapshot_dollar_paren_caught_by_regex():
    """``$(whoami)`` even inside a quoted body is rejected by the strict
    regex (``"`` ``\\`` ``$`` ``\\``` are not in the quoted body's char
    class except as legal ``$VAR`` lookups, which require an alpha char
    after the ``$``). The substring scan exists as defence-in-depth for
    future regex regressions; not normally exercised.
    """
    _, errs = validate_assignments(
        ['PA_VAULT="$(whoami)"', "PA_PROJECTS_DIR=/tmp"]
    )
    assert any(
        e.startswith("pa init: <unparseable>: cannot parse") for e in errs
    )


def test_error_snapshot_missing_required():
    _, errs = validate_assignments([])
    assert "pa init: PA_VAULT: missing required key" in errs
    assert "pa init: PA_PROJECTS_DIR: missing required key" in errs


def test_default_preset_round_trips():
    """The repo's presets/default/config.env content (as the wizard would
    extract it via preset_loader) must pass validate_assignments once
    the two required keys are added.
    """
    out, errs = validate_assignments(
        [*REQUIRED_PAIR, "PA_TERMINAL_BACKEND=auto", "PA_MAIN_TITLE=MAIN", "PA_DAILY_DIR=Daily", 'PA_DAILY_TEMPLATE_PATH="_templates/Daily Note.md"', "PA_WORK_SECTION=Work", "PA_PERSONAL_SECTION=Personal", "PA_FEATURE_NOTE_DIR=PROJECTS", 'PA_STATUS_VALUES="brainstorming,planned,in-progress,in-review,shipped"', "PA_STATUS_SHIPPED=shipped", "PA_DASHBOARD_INTERVAL=2", "PA_DEBUG=0"]
    )
    assert errs == [], errs
    assert len(out) == 13
