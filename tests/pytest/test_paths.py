"""Tests for pa.paths.load_config."""

from __future__ import annotations

from pathlib import Path

import pytest

from pa.paths import Config, ConfigError, load_config


def test_load_config_happy_path(fake_env):
    cfg = load_config()
    assert isinstance(cfg, Config)
    assert cfg.vault == fake_env["vault"]
    assert cfg.projects_dir == fake_env["projects"]
    assert cfg.terminal_backend == "tmux"
    assert cfg.main_title == "MAIN"
    assert cfg.state_dir == fake_env["data"] / "state"
    assert cfg.cache_dir == fake_env["data"] / "cache"
    assert cfg.logs_dir == fake_env["data"] / "logs"


def test_required_vars_unset_raises(fake_env):
    (fake_env["config"]).write_text("PA_PROJECTS_DIR=/tmp\n")
    with pytest.raises(ConfigError, match="PA_VAULT is unset"):
        load_config()


def test_nonexistent_vault_raises(fake_env):
    (fake_env["config"]).write_text(
        f"PA_VAULT=/nonexistent/xyz\nPA_PROJECTS_DIR={fake_env['projects']}\n"
    )
    with pytest.raises(ConfigError, match="does not exist"):
        load_config()


def test_bad_backend_raises(fake_env):
    (fake_env["config"]).write_text(
        f"PA_VAULT={fake_env['vault']}\n"
        f"PA_PROJECTS_DIR={fake_env['projects']}\n"
        "PA_TERMINAL_BACKEND=invalid\n"
    )
    with pytest.raises(ConfigError, match="PA_TERMINAL_BACKEND"):
        load_config()


def test_command_substitution_rejected(fake_env):
    (fake_env["config"]).write_text(
        f'PA_VAULT="$(whoami)"\nPA_PROJECTS_DIR={fake_env["projects"]}\n'
    )
    with pytest.raises(ConfigError, match="cannot parse"):
        load_config()


def test_unknown_key_rejected(fake_env):
    (fake_env["config"]).write_text(
        f"PA_VAULT={fake_env['vault']}\n"
        f"PA_PROJECTS_DIR={fake_env['projects']}\n"
        "PA_BOGUS=x\n"
    )
    with pytest.raises(ConfigError, match="unknown key 'PA_BOGUS'"):
        load_config()


def test_shipped_not_in_status_values(fake_env):
    (fake_env["config"]).write_text(
        f"PA_VAULT={fake_env['vault']}\n"
        f"PA_PROJECTS_DIR={fake_env['projects']}\n"
        "PA_STATUS_VALUES=a,b\n"
        "PA_STATUS_SHIPPED=c\n"
    )
    with pytest.raises(ConfigError, match="PA_STATUS_SHIPPED"):
        load_config()


def test_bad_dashboard_interval(fake_env):
    (fake_env["config"]).write_text(
        f"PA_VAULT={fake_env['vault']}\n"
        f"PA_PROJECTS_DIR={fake_env['projects']}\n"
        "PA_DASHBOARD_INTERVAL=abc\n"
    )
    with pytest.raises(ConfigError, match="must be an integer"):
        load_config()


def test_config_missing(tmp_path, monkeypatch):
    monkeypatch.setenv("PA_CONFIG", str(tmp_path / "missing.sh"))
    monkeypatch.setenv("PA_DATA_DIR", str(tmp_path / "data"))
    with pytest.raises(ConfigError, match="config missing"):
        load_config()
