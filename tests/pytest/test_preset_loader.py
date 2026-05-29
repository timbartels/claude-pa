"""Tests for pa.preset_loader."""

from __future__ import annotations

from pathlib import Path

import pytest

from pa.preset_loader import PresetError, load_preset


@pytest.fixture
def preset_dir(tmp_path: Path) -> Path:
    d = tmp_path / "preset"
    d.mkdir()
    return d


def write(p: Path, body: str) -> None:
    (p / "config.env").write_text(body)


def test_happy_path(preset_dir: Path):
    write(
        preset_dir,
        'PA_VAULT="$HOME/Obsidian/MyVault"\n'
        "PA_PROJECTS_DIR=$HOME/Projects\n"
        "PA_TERMINAL_BACKEND=tmux\n"
        'PA_MAIN_TITLE="MAIN · TEST"\n'
        'PA_SPAWN_PROMPT_TEMPLATE="/workflows:brainstorm {title} — {intent} | {context}"\n',
    )
    values = load_preset(preset_dir)
    assert values["PA_VAULT"].endswith("/Obsidian/MyVault")
    assert values["PA_TERMINAL_BACKEND"] == "tmux"
    assert values["PA_MAIN_TITLE"] == "MAIN · TEST"
    assert "{title}" in values["PA_SPAWN_PROMPT_TEMPLATE"]


def test_missing_config_env(preset_dir: Path):
    with pytest.raises(PresetError, match="missing"):
        load_preset(preset_dir)


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
    ],
)
def test_metachar_rejected(preset_dir: Path, evil: str):
    write(preset_dir, evil + "\n")
    with pytest.raises(PresetError):
        load_preset(preset_dir)


def test_unknown_key_rejected(preset_dir: Path):
    write(preset_dir, "PA_BOGUS=x\n")
    with pytest.raises(PresetError, match="unknown key"):
        load_preset(preset_dir)


def test_brace_placeholders_in_quoted_value_ok(preset_dir: Path):
    """Literal {title}/{intent}/{context} braces in PA_SPAWN_PROMPT_TEMPLATE."""
    write(preset_dir, 'PA_SPAWN_PROMPT_TEMPLATE="hi {title} — {intent}"\n')
    values = load_preset(preset_dir)
    assert values["PA_SPAWN_PROMPT_TEMPLATE"] == "hi {title} — {intent}"


def test_pipe_inside_quoted_value_ok(preset_dir: Path):
    """| is safe inside double quotes — shlex.quote keeps it literal at emit."""
    write(preset_dir, 'PA_MAIN_TITLE="a|b"\n')
    values = load_preset(preset_dir)
    assert values["PA_MAIN_TITLE"] == "a|b"


def test_tim_preset_loads(tmp_path: Path):
    """Repo's own obsidian-ce preset must parse cleanly."""
    repo_root = Path(__file__).resolve().parents[2]
    values = load_preset(repo_root / "presets" / "obsidian-ce")
    assert "PA_VAULT" in values
    assert "PA_PROJECTS_DIR" in values
    assert values["PA_TERMINAL_BACKEND"] == "wezterm"
    assert "shipped" in values["PA_STATUS_VALUES"]
