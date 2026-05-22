#!/usr/bin/env python3
"""Render a single dashboard frame for ``pa watch``.

Reads ``$PA_STATE_DIR/*.json`` and emits a styled ANSI frame with two
sections: project panes (one line per repo) and cross-pane todos. Vault
root, projects dir, cache dir, and feature-note layout all come from the
user's claude-pa config via :func:`pa.paths.load_config`.

Entry point: ``python3 -m pa.dashboard_render`` (no arguments).
"""

import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path

from pa.paths import Config, ConfigError, load_config

FRESH_TTL_S = 8  # row is considered "fresh" if state mtime changed within this window
SPARK_BUCKETS = 12  # split last 12 minutes into 12 1-minute buckets
SPARK_CHARS = "▁▂▃▄▅▆▇█"
EXTRA_CACHE_TTL_S = 60  # PR / git-log cache refresh interval

_CONFIG: Config | None = None


def _config() -> Config:
    """Return the loaded :class:`Config`. ``render`` sets this before fan-out."""
    if _CONFIG is None:
        raise RuntimeError("pa.dashboard_render: config not loaded; call main() first")
    return _CONFIG


def load_event_log(state_dir: Path, max_lines: int = 800) -> list[dict]:
    log_path = state_dir / "events.log"
    if not log_path.exists():
        return []
    try:
        # Read last N lines efficiently
        with log_path.open("rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            block = 65536
            data = b""
            while size > 0 and data.count(b"\n") <= max_lines:
                step = min(block, size)
                size -= step
                fh.seek(size)
                data = fh.read(step) + data
        lines = data.decode("utf-8", errors="ignore").splitlines()[-max_lines:]
    except OSError:
        return []
    out: list[dict] = []
    for ln in lines:
        try:
            out.append(json.loads(ln))
        except json.JSONDecodeError:
            continue
    return out


def sparkline_for(events: list[dict], repo: str) -> str:
    """Return a SPARK_BUCKETS-char sparkline of events/minute over the last N minutes for one repo."""
    if not events:
        return " " * SPARK_BUCKETS
    now = datetime.now()
    buckets = [0] * SPARK_BUCKETS
    for e in events:
        if e.get("repo") != repo:
            continue
        try:
            ts = datetime.fromisoformat(e.get("ts", ""))
        except (TypeError, ValueError):
            continue
        delta_min = int((now - ts).total_seconds() // 60)
        if 0 <= delta_min < SPARK_BUCKETS:
            buckets[SPARK_BUCKETS - 1 - delta_min] += 1
    if max(buckets) == 0:
        return color(" " * SPARK_BUCKETS, "gray", dim=True)
    peak = max(buckets)
    chars = []
    for c in buckets:
        if c == 0:
            chars.append(" ")
        else:
            idx = min(len(SPARK_CHARS) - 1, int(c / peak * (len(SPARK_CHARS) - 1)))
            chars.append(SPARK_CHARS[idx])
    return color("".join(chars), "cyan")


def load_pane_extras_cache() -> dict:
    cache_dir = _config().cache_dir
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_path = cache_dir / "pane_extras.json"
    if not cache_path.exists():
        return {}
    try:
        return json.loads(cache_path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def save_pane_extras_cache(data: dict) -> None:
    cache_dir = _config().cache_dir
    cache_dir.mkdir(parents=True, exist_ok=True)
    (cache_dir / "pane_extras.json").write_text(json.dumps(data))


def fetch_pane_extras(repo: str) -> dict:
    """Return {commits_today, pr_state, pr_review, pr_ci} via git + gh. Lazy/cached upstream."""
    import subprocess
    out: dict = {}
    repo_path = _config().projects_dir / repo
    if not repo_path.is_dir():
        return out
    try:
        email = subprocess.check_output(
            ["git", "-C", str(repo_path), "config", "user.email"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        commits = subprocess.check_output(
            [
                "git", "-C", str(repo_path), "log",
                "--since=midnight", f"--author={email}", "--oneline",
            ],
            stderr=subprocess.DEVNULL,
        ).decode().splitlines()
        out["commits_today"] = len(commits)
    except subprocess.CalledProcessError:
        pass

    try:
        branch = subprocess.check_output(
            ["git", "-C", str(repo_path), "rev-parse", "--abbrev-ref", "HEAD"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        out["branch"] = branch
        # PR for this branch in the repo's GH remote
        prs = subprocess.check_output(
            [
                "gh", "pr", "list",
                "--repo", f"{_gh_remote(repo_path)}",
                "--head", branch,
                "--state", "all",
                "--json", "number,state,reviewDecision,statusCheckRollup,url",
                "--limit", "1",
            ],
            stderr=subprocess.DEVNULL,
        ).decode()
        prs_data = json.loads(prs or "[]")
        if prs_data:
            pr = prs_data[0]
            out["pr_number"] = pr.get("number")
            out["pr_state"] = pr.get("state")
            out["pr_review"] = pr.get("reviewDecision") or "-"
            checks = pr.get("statusCheckRollup") or []
            ci_states = {c.get("conclusion") or c.get("status") for c in checks}
            if ci_states & {"FAILURE", "ERROR", "TIMED_OUT"}:
                out["pr_ci"] = "FAIL"
            elif ci_states & {"IN_PROGRESS", "PENDING", "QUEUED"}:
                out["pr_ci"] = "RUN"
            elif ci_states & {"SUCCESS"}:
                out["pr_ci"] = "OK"
            else:
                out["pr_ci"] = "-"
    except (subprocess.CalledProcessError, FileNotFoundError, json.JSONDecodeError):
        pass
    return out


def spotify_now() -> str | None:
    import subprocess
    try:
        res = subprocess.run(
            ["osascript", "-e", 'tell application "Spotify" to if it is running then return name of current track & " — " & artist of current track'],
            capture_output=True,
            text=True,
            timeout=2,
        )
        out = res.stdout.strip()
        return out or None
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError, FileNotFoundError):
        return None


_SPOTIFY_CACHE: dict = {}


def spotify_state() -> tuple[bool, str | None]:
    """Return (is_playing, 'Track — Artist' or None). Cached 3s to keep refresh cheap."""
    import subprocess
    now_ts = datetime.now().timestamp()
    if _SPOTIFY_CACHE and (now_ts - _SPOTIFY_CACHE.get("_ts", 0)) < 3:
        return _SPOTIFY_CACHE["data"]
    script = '''
    tell application "Spotify"
        if it is running then
            try
                set s to player state as string
                set t to name of current track & " — " & artist of current track
                return s & "||" & t
            on error
                return ""
            end try
        end if
    end tell
    '''
    try:
        res = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=2,
        )
        out = res.stdout.strip()
        if not out:
            data = (False, None)
        else:
            state, _, track = out.partition("||")
            data = (state == "playing", track or None)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        data = (False, None)
    _SPOTIFY_CACHE["data"] = data
    _SPOTIFY_CACHE["_ts"] = now_ts
    return data


def _extras() -> dict:
    """Optional dashboard-only knobs sourced from env vars.

    Not part of the core ``PA_*`` config schema because they're
    nice-to-have rendering options, not required for any subcommand:

      ``PA_WEATHER_CITY``  city string for the wttr.in widget
      ``PA_WORK_ORGS``     comma-separated GitHub org filter for the PR list
    """
    work_orgs_env = os.environ.get("PA_WORK_ORGS", "")
    return {
        "city": os.environ.get("PA_WEATHER_CITY") or os.environ.get("WEATHER_CITY", ""),
        "work_orgs": [o.strip() for o in work_orgs_env.split(",") if o.strip()],
    }


def weather_now(cache: dict) -> str | None:
    import subprocess
    entry = cache.get("_weather")
    now_ts = datetime.now().timestamp()
    if entry and (now_ts - entry.get("_ts", 0)) < 600:
        return entry.get("text")
    # City precedence: PA_WEATHER_CITY > WEATHER_CITY > IP geolocation (empty path)
    city = _extras()["city"]
    url = f"wttr.in/{city}?format=3" if city else "wttr.in/?format=3"
    try:
        res = subprocess.run(
            ["curl", "-fsS", "--max-time", "3", url],
            capture_output=True,
            text=True,
            timeout=4,
        )
        text = res.stdout.strip()
        if text:
            cache["_weather"] = {"text": text, "_ts": now_ts}
            return text
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return None


def activity_sparkline(events: list[dict], hours: int = 12) -> tuple[str, int]:
    """Return (sparkline, total_count) of Edit/Write/Bash events per hour over last `hours`."""
    if not events:
        return ("", 0)
    coded_tools = {"Edit", "Write", "MultiEdit", "Bash", "NotebookEdit"}
    now = datetime.now()
    buckets = [0] * hours
    total = 0
    for e in events:
        if e.get("event") != "PreToolUse":
            continue
        if e.get("tool") not in coded_tools:
            continue
        try:
            ts = datetime.fromisoformat(e.get("ts", ""))
        except (TypeError, ValueError):
            continue
        delta_hr = int((now - ts).total_seconds() // 3600)
        if 0 <= delta_hr < hours:
            buckets[hours - 1 - delta_hr] += 1
            total += 1
    if max(buckets) == 0:
        return ("", total)
    peak = max(buckets)
    chars = []
    for c in buckets:
        if c == 0:
            chars.append(" ")
        else:
            idx = min(len(SPARK_CHARS) - 1, int(c / peak * (len(SPARK_CHARS) - 1)))
            chars.append(SPARK_CHARS[idx])
    return ("".join(chars), total)


def fetch_open_prs(cache: dict) -> list[dict]:
    """All open PRs authored by current user. Cached 60s.
    Returns [{repo, number, title, headRefName, reviewDecision, ci, url}, ...]
    """
    import subprocess
    entry = cache.get("_open_prs")
    now_ts = datetime.now().timestamp()
    if entry and (now_ts - entry.get("_ts", 0)) < 60:
        return entry.get("data") or []

    # gh search prs doesn't support reviewDecision/statusCheckRollup — use the basic fields only.
    try:
        raw = subprocess.check_output(
            [
                "gh", "search", "prs",
                "--author", "@me",
                "--state", "open",
                "--json", "repository,number,title,url,isDraft,updatedAt",
                "--limit", "30",
            ],
            stderr=subprocess.DEVNULL,
            timeout=6,
        ).decode()
        items = json.loads(raw or "[]")
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError, json.JSONDecodeError):
        items = []

    work_orgs = _extras()["work_orgs"]

    out: list[dict] = []
    for it in items:
        repo_obj = it.get("repository") or {}
        repo = repo_obj.get("name") or ""
        owner_repo = repo_obj.get("nameWithOwner") or ""
        # Filter to work orgs if configured
        if work_orgs and not any(owner_repo.startswith(f"{org}/") for org in work_orgs):
            continue
        out.append({
            "repo": repo,
            "number": it.get("number"),
            "title": it.get("title") or "",
            "draft": bool(it.get("isDraft")),
            "updated": it.get("updatedAt") or "",
            "url": it.get("url") or "",
        })

    # Sort: drafts at bottom, then by most recent update
    out.sort(key=lambda p: (p["draft"], -(datetime.fromisoformat(p["updated"].replace("Z", "+00:00")).timestamp() if p["updated"] else 0)))

    cache["_open_prs"] = {"data": out, "_ts": now_ts}
    return out


def code_history_7d(cache: dict) -> dict | None:
    """Aggregate commits + lines added per day across ~/Projects/* for the last 7 days.

    Returns {dates: [...], commits: [...], lines: [...], total_lines, total_commits}.
    Cached 5 minutes.
    """
    import subprocess
    entry = cache.get("_code7d")
    now_ts = datetime.now().timestamp()
    if entry and (now_ts - entry.get("_ts", 0)) < 300:
        return entry.get("data")

    projects = _config().projects_dir
    if not projects.is_dir():
        return None

    dates = [(datetime.now().date() - timedelta(days=i)) for i in range(6, -1, -1)]
    commits_by_day = {d.isoformat(): 0 for d in dates}
    lines_by_day = {d.isoformat(): 0 for d in dates}

    try:
        # Use a single global git config for email
        email = subprocess.check_output(
            ["git", "config", "--global", "user.email"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
    except subprocess.CalledProcessError:
        email = ""

    since = (datetime.now() - timedelta(days=7)).strftime("%Y-%m-%d")

    for repo in projects.iterdir():
        if not (repo / ".git").is_dir():
            continue
        try:
            log = subprocess.check_output(
                [
                    "git", "-C", str(repo), "log",
                    f"--since={since}",
                    f"--author={email}" if email else "--all",
                    "--shortstat",
                    "--pretty=format:::COMMIT::%aI",
                ],
                stderr=subprocess.DEVNULL,
                timeout=5,
            ).decode()
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            continue

        current_day = None
        for line in log.splitlines():
            if line.startswith("::COMMIT::"):
                iso = line.removeprefix("::COMMIT::").strip()
                try:
                    day = datetime.fromisoformat(iso).date().isoformat()
                except ValueError:
                    current_day = None
                    continue
                if day in commits_by_day:
                    commits_by_day[day] += 1
                    current_day = day
                else:
                    current_day = None
            elif current_day and ("insertion" in line or "deletion" in line):
                m = re.search(r"(\d+)\s+insertion", line)
                if m:
                    lines_by_day[current_day] += int(m.group(1))

    data = {
        "dates": [d.isoformat() for d in dates],
        "commits": [commits_by_day[d.isoformat()] for d in dates],
        "lines": [lines_by_day[d.isoformat()] for d in dates],
        "total_lines": sum(lines_by_day.values()),
        "total_commits": sum(commits_by_day.values()),
    }
    cache["_code7d"] = {"data": data, "_ts": now_ts}
    return data


def confetti_check(extras_cache: dict) -> list[str]:
    """Detect feature notes that flipped to shipped since last scan. Vault rglob cached 30s."""
    seen = extras_cache.setdefault("_shipped_seen", [])
    seen_set = set(seen)
    now_ts = datetime.now().timestamp()
    last_scan = extras_cache.get("_confetti_ts", 0)
    if (now_ts - last_scan) < 30:
        return []
    extras_cache["_confetti_ts"] = now_ts

    new_shipped: list[str] = []
    proj = _config().feature_notes_root
    if not proj.is_dir():
        return []
    for note in proj.rglob("*.md"):
        try:
            body = note.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        fm = re.match(r"---\n(.*?)\n---\n", body, re.DOTALL)
        if not fm:
            continue
        status_m = re.search(r"^status:\s*(\S+)", fm.group(1), re.MULTILINE)
        tags_m = re.search(r"^tags:\s*\[(.*?)\]", fm.group(1), re.MULTILINE)
        if not status_m or "feature" not in (tags_m.group(1) if tags_m else ""):
            continue
        if status_m.group(1).lower() != "shipped":
            continue
        if note.stem in seen_set:
            continue
        new_shipped.append(note.stem)
        seen.append(note.stem)
    extras_cache["_shipped_seen"] = seen[-50:]
    return new_shipped


def _gh_remote(repo_path: Path) -> str:
    import subprocess
    try:
        url = subprocess.check_output(
            ["git", "-C", str(repo_path), "remote", "get-url", "origin"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        # Normalize git@github.com:owner/repo(.git) and https://github.com/owner/repo(.git)
        m = re.search(r"[:/]([\w.-]+)/([\w.-]+?)(?:\.git)?$", url)
        if m:
            return f"{m.group(1)}/{m.group(2)}"
    except subprocess.CalledProcessError:
        pass
    return ""


def get_pane_extras(repo: str, cache: dict) -> dict:
    entry = cache.get(repo)
    now_ts = datetime.now().timestamp()
    if entry and (now_ts - entry.get("_ts", 0)) < EXTRA_CACHE_TTL_S:
        return entry
    fresh = fetch_pane_extras(repo)
    fresh["_ts"] = now_ts
    cache[repo] = fresh
    return fresh

ESC = "\033["
RESET = f"{ESC}0m"
BOLD = f"{ESC}1m"
DIM = f"{ESC}2m"
ITALIC = f"{ESC}3m"
CLEAR_LINE = f"{ESC}K"
FG = {
    "green": f"{ESC}32m",
    "yellow": f"{ESC}33m",
    "red": f"{ESC}31m",
    "cyan": f"{ESC}36m",
    "magenta": f"{ESC}35m",
    "gray": f"{ESC}90m",
    "white": f"{ESC}97m",
    # Editorial palette — restrained
    "head": f"{ESC}97m",        # bright white for headlines
    "num": f"{ESC}97m",         # bright white for numbers
    "caption": f"{ESC}90m",     # dim gray for captions/labels
    "accent": f"{ESC}38;5;215m", # warm amber (256-color) for emphasis
    "rule": f"{ESC}90m",        # hairline rule
    "alert": f"{ESC}38;5;203m", # muted coral for alerts
    "good": f"{ESC}38;5;108m",  # muted sage for positive
}

STATUS_MARK = {"in_progress": "~", "pending": " ", "completed": "x"}


def color(text: str, fg: str = "white", *, bold: bool = False, dim: bool = False, italic: bool = False) -> str:
    parts = []
    if bold:
        parts.append(BOLD)
    if dim:
        parts.append(DIM)
    if italic:
        parts.append(ITALIC)
    parts.append(FG.get(fg, FG["white"]))
    parts.append(text)
    parts.append(RESET)
    return "".join(parts)


def kicker(label: str) -> str:
    """Magazine-style small kicker label above a stat."""
    return color(label.upper(), "caption", italic=True)


def display_num(s: str) -> str:
    return color(s, "num", bold=True)


def caption(s: str) -> str:
    return color(s, "caption")


def headline(s: str) -> str:
    return color(s, "head", bold=True)


def age_seconds(iso: str) -> int | None:
    try:
        return int((datetime.now() - datetime.fromisoformat(iso)).total_seconds())
    except (TypeError, ValueError):
        return None


def fmt_age(secs: int | None) -> tuple[str, str]:
    """Return (text, color-name)."""
    if secs is None:
        return ("?", "gray")
    if secs < 60:
        return (f"{secs}s", "green")
    if secs < 600:
        return (f"{secs // 60}m{secs % 60:02d}s", "green")
    if secs < 1800:
        return (f"{secs // 60}m", "yellow")
    return (f"{secs // 60}m", "red")


def pane_state(state: dict, age: int | None) -> tuple[str, str]:
    """Return ('●' / '○' / '◐' / '✕', color). Active panes pulse via per-frame tick."""
    if state.get("idle"):
        return ("○", "caption")
    if age is not None and age > 1800:
        return ("✕", "alert")
    if age is not None and age > 600:
        return ("◐", "accent")
    # Active: pulse between filled and hollow circle each frame
    cache_dir = _config().cache_dir
    cache_dir.mkdir(parents=True, exist_ok=True)
    tick_path = cache_dir / "tick.txt"
    pulse = _read_counter(tick_path) % 2  # already incremented in header()
    glyph = "●" if pulse else "◉"
    return (glyph, "good")


def hr(width: int, char: str = "─") -> str:
    return color(char * width, "gray", dim=True)


SPINNER_FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"


def _read_counter(path: Path) -> int:
    try:
        return int(path.read_text().strip())
    except (OSError, ValueError):
        return 0


def _write_counter(path: Path, val: int) -> None:
    try:
        path.write_text(str(val))
    except OSError:
        pass


def header(title: str, width: int) -> str:
    """Editorial masthead — blinking clock colon as gentle liveness signal."""
    now = datetime.now()
    cache_dir = _config().cache_dir
    cache_dir.mkdir(parents=True, exist_ok=True)
    tick_path = cache_dir / "tick.txt"
    tick = (_read_counter(tick_path) + 1) % 2
    _write_counter(tick_path, tick)
    colon = ":" if tick else " "  # blink between visible and invisible
    clock = now.strftime(f"%H{colon}%M")
    date_str = now.strftime("%A %d %B")
    left = (
        f"  {color('PA', 'accent', bold=True)} "
        f"{color('Watch', 'caption', italic=True)}"
    )
    right = (
        f"{color(date_str, 'caption')}    "
        f"{color(clock, 'num', bold=True)}  "
    )
    visible_left = "  PA Watch"
    visible_right = f"{date_str}    {clock}  "
    pad_n = max(1, width - len(visible_left) - len(visible_right))
    return left + (" " * pad_n) + right


def section(label: str, suffix: str = "") -> str:
    """Editorial section header: small-caps headline + hairline rule below (emitted separately)."""
    head = "  " + color(label.upper(), "head", bold=True)
    if suffix:
        head += "  " + color(suffix, "caption")
    return head


def section_rule(width: int) -> str:
    """Thin hairline rule that follows a section header."""
    return color("  " + "─" * max(8, width - 4), "rule", dim=True)


_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")


def vlen(s: str) -> int:
    """Visible length: strip ANSI escapes, count each char (treats unicode as 1)."""
    return len(_ANSI_RE.sub("", s))


def pad(s: str, n: int, *, align: str = "left", fill: str = " ") -> str:
    """Pad string `s` to visible length `n` (ANSI-aware)."""
    diff = max(0, n - vlen(s))
    if align == "right":
        return fill * diff + s
    if align == "center":
        l = diff // 2
        return fill * l + s + fill * (diff - l)
    return s + fill * diff


_FRAME_BUF: list[str] = []


def emit(line: str = "") -> None:
    """Buffer a line with a trailing clear-to-end-of-line. Flushed once per frame."""
    _FRAME_BUF.append(line + CLEAR_LINE + "\n")


def flush_frame() -> None:
    sys.stdout.write("".join(_FRAME_BUF))
    sys.stdout.flush()
    _FRAME_BUF.clear()


def pill(text: str, *, fg: str = "white", bg_code: str = "") -> str:
    """Render text as a rounded pill badge using brackets + color."""
    return f"{color('▐', fg)}{color(' ' + text + ' ', fg, bold=True)}{color('▌', fg)}"


def _humanize(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)


def _wide_sparkline(values: list[int], slot: int = 3) -> str:
    """Render a sparkline with `slot`-char width per bucket so it reads bigger."""
    if not values or max(values) == 0:
        return " " * (slot * len(values))
    peak = max(values)
    out = []
    for v in values:
        if v == 0:
            out.append(" " * slot)
            continue
        idx = min(len(SPARK_CHARS) - 1, int(v / peak * (len(SPARK_CHARS) - 1)))
        # Center the spark char in its slot
        ch = SPARK_CHARS[idx]
        out.append(pad(ch, slot, align="center"))
    return "".join(out)


def progress_bar(done: int, total: int, width: int = 12) -> str:
    if total <= 0:
        return ""
    filled = round(width * done / total)
    bar = "█" * filled + "░" * (width - filled)
    pct = int(round(100 * done / total))
    bar_color = "green" if pct >= 80 else "yellow" if pct >= 40 else "cyan"
    return f"{color(bar, bar_color)} {color(f'{done}/{total}', 'gray', dim=True)}"


def vault_work_items(max_items: int = 8) -> list[tuple[str, str, tuple[int, int] | None]]:
    """Return [(state, text, sub_progress)] for top-level checkboxes in today's ## Work section.

    state: "done" | "in-dev" | "partial" | "open"
    sub_progress: (done_subs, total_subs) or None

    in-dev = parent unchecked but wikilinked feature note has `status: in-dev`.
    """
    today = datetime.now().strftime("%Y-%m-%d")
    daily = _config().daily_path / f"{today}.md"
    if not daily.exists():
        return []
    text = daily.read_text(encoding="utf-8", errors="ignore")
    m = re.search(r"^## Work\n(.*?)(?=^## |\Z)", text, re.MULTILINE | re.DOTALL)
    if not m:
        return []

    lines = m.group(1).splitlines()
    out: list[tuple[str, str, tuple[int, int] | None]] = []

    i = 0
    while i < len(lines):
        line = lines[i]
        parent_m = re.match(r"^- \[( |[xX])\]\s+(.+)$", line)
        if not parent_m:
            i += 1
            continue
        parent_done = parent_m.group(1) in ("x", "X")
        clean = re.sub(
            r"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]",
            lambda x: x.group(2) or x.group(1).split("/")[-1],
            parent_m.group(2),
        ).strip()

        # Scan indented sub-checkboxes underneath
        sub_done = 0
        sub_total = 0
        j = i + 1
        while j < len(lines):
            sub = lines[j]
            if not sub.strip():
                j += 1
                continue
            # Stop at next top-level checkbox or any other non-indented line
            if not sub.startswith((" ", "\t")):
                break
            sub_m = re.match(r"^\s+- \[( |[xX])\]\s+\S", sub)
            if sub_m:
                sub_total += 1
                if sub_m.group(1) in ("x", "X"):
                    sub_done += 1
            j += 1

        # Look up feature note status if this parent has a wikilink
        link_m = re.search(r"\[\[(PROJECTS/[^\]|]+)", parent_m.group(2))
        feature_status = ""
        if link_m:
            note_path = _config().vault / f"{link_m.group(1).strip()}.md"
            try:
                body = note_path.read_text(encoding="utf-8")
                fm = re.match(r"---\n(.*?)\n---\n", body, re.DOTALL)
                if fm:
                    sm = re.search(r"^status:\s*(\S+)", fm.group(1), re.MULTILINE)
                    if sm:
                        feature_status = sm.group(1).lower()
            except OSError:
                pass

        if parent_done:
            state = "done"
        elif feature_status == "in-dev":
            state = "in-dev"
        elif sub_total and sub_done == sub_total:
            state = "done"
        elif sub_total and sub_done > 0:
            state = "partial"
        else:
            state = "open"

        out.append((state, clean, (sub_done, sub_total) if sub_total else None))
        if len(out) >= max_items:
            break
        i = j

    return out


def vault_counts() -> dict[str, tuple[int, int]]:
    """Return {section_name: (open, done)} for today's daily note, skipping empty placeholders."""
    today = datetime.now().strftime("%Y-%m-%d")
    daily = _config().daily_path / f"{today}.md"
    out: dict[str, tuple[int, int]] = {}
    if not daily.exists():
        return out
    text = daily.read_text(encoding="utf-8", errors="ignore")
    for section_name in ("Work", "Personal"):
        m = re.search(
            rf"^## {section_name}\n(.*?)(?=^## |\Z)", text, re.MULTILINE | re.DOTALL
        )
        if not m:
            continue
        body = m.group(1)
        open_n = len(re.findall(r"^\s*- \[ \]\s+\S", body, re.MULTILINE))
        done_n = len(re.findall(r"^\s*- \[[xX]\]\s+\S", body, re.MULTILINE))
        if open_n + done_n == 0:
            continue
        out[section_name] = (open_n, done_n)
    return out


def vault_progress(counts: dict[str, tuple[int, int]]) -> str | None:
    parts: list[str] = []
    for section_name, (open_n, done_n) in counts.items():
        bar = progress_bar(done_n, open_n + done_n, width=10)
        parts.append(f"{color(section_name, 'cyan', bold=True)} {bar}")
    if not parts:
        return None
    return "   ".join(parts)


def feature_notes_progress() -> list[tuple[str, int, int, str]]:
    """Return [(title, done, total, status)] for non-shipped feature notes that have checkboxes."""
    proj = _config().feature_notes_root
    if not proj.is_dir():
        return []
    rows: list[tuple[str, int, int, str]] = []
    for note in proj.rglob("*.md"):
        try:
            body = note.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        fm = re.match(r"---\n(.*?)\n---\n", body, re.DOTALL)
        if not fm:
            continue
        tags = re.search(r"^tags:\s*\[(.*?)\]", fm.group(1), re.MULTILINE)
        status_m = re.search(r"^status:\s*(\S+)", fm.group(1), re.MULTILINE)
        if not status_m:
            continue
        if "feature" not in (tags.group(1) if tags else ""):
            continue
        status = status_m.group(1).lower()
        if status == "shipped":
            continue
        done_n = len(re.findall(r"^\s*- \[[xX]\]", body, re.MULTILINE))
        open_n = len(re.findall(r"^\s*- \[ \]", body, re.MULTILINE))
        if done_n + open_n == 0:
            continue
        rows.append((note.stem, done_n, done_n + open_n, status))
    rows.sort(key=lambda r: (-(r[1] / r[2] if r[2] else 0), r[0]))
    return rows[:6]


def load_prev_mtimes(state_dir: Path) -> dict[str, float]:
    f = state_dir / ".prev_mtimes.json"
    if not f.exists():
        return {}
    try:
        return json.loads(f.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def save_prev_mtimes(state_dir: Path, mtimes: dict[str, float]) -> None:
    f = state_dir / ".prev_mtimes.json"
    try:
        f.write_text(json.dumps(mtimes))
    except OSError:
        pass


def live_pane_ids() -> set[str]:
    """Return set of currently-alive wezterm pane IDs (as strings)."""
    try:
        out = subprocess.run(
            ["wezterm", "cli", "list"],
            capture_output=True, text=True, timeout=2, check=False,
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return set()
    ids: set[str] = set()
    for ln in out.splitlines()[1:]:
        parts = ln.split()
        if len(parts) >= 3 and parts[2].isdigit():
            ids.add(parts[2])
    return ids


def render(state_dir: Path) -> None:
    width = shutil.get_terminal_size((80, 24)).columns
    now_epoch = datetime.now().timestamp()
    alive = live_pane_ids()

    files = (
        sorted(
            f for f in state_dir.glob("*.json")
            if not f.name.startswith(".")
            and not f.name.startswith("vault-session-")
        )
        if state_dir.is_dir()
        else []
    )
    rows = []
    new_mtimes: dict[str, float] = {}
    prev_mtimes = load_prev_mtimes(state_dir)
    for f in files:
        try:
            s = json.loads(f.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        # Skip ghost panes: state file present but wezterm pane no longer exists.
        pane_id = str(s.get("pane_id") or "")
        if alive and pane_id and pane_id not in alive:
            continue
        mtime = f.stat().st_mtime
        repo_key = s.get("repo") or f.stem
        new_mtimes[repo_key] = mtime
        # Fresh = mtime changed since previous render AND happened within FRESH_TTL_S
        prev = prev_mtimes.get(repo_key)
        s["_fresh"] = bool(
            prev is not None and mtime > prev and (now_epoch - mtime) <= FRESH_TTL_S
        )
        rows.append(s)
    save_prev_mtimes(state_dir, new_mtimes)

    # Aggregate counts
    active = sum(1 for s in rows if not s.get("idle"))
    idle = sum(1 for s in rows if s.get("idle"))
    stalled = sum(
        1
        for s in rows
        if not s.get("idle")
        and (age_seconds(s.get("last_update", "")) or 0) > 600
    )
    def _needs_input(s: dict) -> bool:
        # An idle pane can't need input — Stop has fired and Claude is back at the prompt.
        if s.get("idle"):
            return False
        ev = s.get("last_event")
        tool = s.get("last_tool")
        if ev in ("Notification", "PermissionRequest"):
            return True
        # Claude is paused inside an AskUserQuestion / waiting for user — PreToolUse fired, no Stop yet
        if ev == "PreToolUse" and tool == "AskUserQuestion":
            return True
        return False

    attention_rows = [s for s in rows if _needs_input(s)]
    attention = len(attention_rows)
    summary = (
        f"{color(str(len(rows)), 'white', bold=True)} panes"
        f"  •  {color(str(active), 'green')} active"
        f"  •  {color(str(idle), 'gray', dim=True)} idle"
        f"  •  {color(str(stalled), 'yellow' if stalled else 'gray', dim=stalled == 0)} stalled"
        f"  •  {color(str(attention), 'red' if attention else 'gray', dim=attention == 0)} need input"
    )

    # Load event log + pane extras
    events_log = load_event_log(state_dir, max_lines=400)
    extras_cache = load_pane_extras_cache()

    # Masthead
    emit(header("", width))
    emit()
    emit(section_rule(width))
    emit()

    # Aggregate counts — kicker + display numbers inline
    summary_line = (
        f"  {display_num(str(len(rows)))} {caption('panes')}   "
        f"{display_num(str(active))} {caption('active')}   "
        f"{display_num(str(idle))} {caption('idle')}   "
        f"{display_num(str(stalled))} {color('stalled', 'alert' if stalled else 'caption')}   "
        f"{display_num(str(attention))} {color('need input', 'alert' if attention else 'caption')}"
    )
    emit(summary_line)

    # Ambient strip — weather only (Spotify lives in the footer visualizer)
    w = weather_now(extras_cache)
    if w:
        emit()
        emit("  " + color(w, "caption", italic=True))

    # Attention banner — any pane currently waiting on user input
    if attention_rows:
        emit()
        cache_dir = _config().cache_dir
        cache_dir.mkdir(parents=True, exist_ok=True)
        tick_path = cache_dir / "tick.txt"
        pulse = _read_counter(tick_path) % 2  # already incremented in header()
        bell = "▲" if pulse else "△"
        for s in attention_rows:
            repo = s.get("repo", "?")
            ev = s.get("last_event", "?")
            tool = s.get("last_tool") or ""
            reason = "permission" if ev == "PermissionRequest" else ("question" if tool == "AskUserQuestion" else "notification")
            pane_id = s.get("pane_id") or "?"
            emit(
                color(f"  {bell}  ATTENTION", "alert", bold=True)
                + "  "
                + color(repo, "head", bold=True)
                + color(f"  needs {reason}", "alert")
                + color(f"   pane {pane_id}", "caption", dim=True)
            )

    # Newly-shipped feature notes — quiet announcement
    shipped_new = confetti_check(extras_cache)
    for title in shipped_new:
        emit()
        emit(color("  Shipped — ", "accent", bold=True) + headline(title))

    # Calm note when no stalls / attention / open work
    counts = vault_counts()
    open_work = counts.get("Work", (0, 0))[0]
    if (
        rows
        and stalled == 0
        and attention == 0
        and open_work == 0
        and counts.get("Work", (0, 0))[1] > 0
    ):
        emit()
        emit(color("  All clear today.", "good", italic=True))

    # CODE ACTIVITY
    act_spark, act_total = activity_sparkline(events_log, hours=12)
    hist = code_history_7d(extras_cache)

    if act_total or (hist and hist["total_lines"]):
        margin = 2
        label_w = 11
        total_w = 16
        spark_w = max(8, width - margin - label_w - total_w - 4)

        emit()
        emit(section("CODE ACTIVITY"))
        emit()

        # 12h tool-call sparkline — scale to spark_w by repeating
        if act_total:
            buckets = SPARK_BUCKETS
            slot = max(1, spark_w // buckets)
            wide_spark = "".join(c * slot for c in act_spark)
            wide_spark = pad(wide_spark, spark_w, align="left")
            label = color("12h tools", "cyan")
            spark = color(wide_spark, "green")
            total_str = color(_humanize(act_total) + " calls", "gray", dim=True)
            emit(
                f"  {pad(label, label_w)}"
                f"{pad(spark, spark_w)}  "
                f"{pad(total_str, total_w, align='right')}"
            )

        # 7-day lines + commits
        if hist and hist["total_lines"]:
            days = 7
            slot = max(2, spark_w // days)
            content_w = slot * days  # actual chars used by the day grid

            line_spark = _wide_sparkline(hist["lines"], slot=slot)
            commit_spark = _wide_sparkline(hist["commits"], slot=slot)
            line_spark = pad(line_spark, spark_w, align="left")
            commit_spark = pad(commit_spark, spark_w, align="left")

            line_label = color("7d lines", "cyan")
            line_bar = color(line_spark, "green", bold=True)
            line_total = color(
                _humanize(hist["total_lines"]) + " insertions", "gray", dim=True
            )
            emit(
                f"  {pad(line_label, label_w)}"
                f"{pad(line_bar, spark_w)}  "
                f"{pad(line_total, total_w, align='right')}"
            )

            # Day labels row, aligned under each slot
            day_row = ""
            today_idx = days - 1
            for i, d in enumerate(hist["dates"]):
                try:
                    lab = datetime.fromisoformat(d).strftime("%a")[:2]
                except ValueError:
                    lab = "??"
                cell = pad(lab, slot, align="center")
                if i == today_idx:
                    day_row += color(cell, "yellow", bold=True)
                else:
                    day_row += color(cell, "gray", dim=True)
            emit(f"  {pad('', label_w)}{day_row}")

            commit_label = color("7d commits", "cyan")
            commit_bar = color(commit_spark, "magenta", bold=True)
            commit_total = color(f"{hist['total_commits']} commits", "gray", dim=True)
            emit(
                f"  {pad(commit_label, label_w)}"
                f"{pad(commit_bar, spark_w)}  "
                f"{pad(commit_total, total_w, align='right')}"
            )
        emit()

    # Today's progress + work items
    vp_counts = vault_counts()
    if vp_counts:
        emit()
        emit(section("TODAY"))
        for sect_name, (open_n, done_n) in vp_counts.items():
            bar = progress_bar(done_n, open_n + done_n, width=10)
            emit(
                f"  {caption(sect_name.lower())}  "
                f"{bar}  "
                f"{display_num(f'{done_n}/{open_n + done_n}')}"
            )
        # Today's Work items — parent checkboxes with partial-state mark
        items = vault_work_items(max_items=8)
        if items:
            emit()
            for state, text, prog in items:
                if state == "done":
                    mark = color("☑", "good")
                    t_col = "good"
                elif state == "in-dev":
                    mark = color("▣", "accent")  # filled square in amber — on dev, not yet live
                    t_col = "accent"
                elif state == "partial":
                    mark = color("◐", "accent")
                    t_col = "head"
                else:
                    mark = color("☐", "caption", dim=True)
                    t_col = "head"
                prog_str = (
                    color(f"  ({prog[0]}/{prog[1]})", "caption", dim=True)
                    if prog and state != "done"
                    else ""
                )
                emit(f"  {mark}  {color(text[: width - 10], t_col)}{prog_str}")

    # Attention banner
    blocked = []
    for s in rows:
        age = age_seconds(s.get("last_update", ""))
        ev = s.get("last_event", "")
        if ev in ("Notification", "PermissionRequest"):
            blocked.append((s.get("repo", "?"), "needs input"))
        elif not s.get("idle") and age is not None and age > 600:
            blocked.append((s.get("repo", "?"), f"stalled {age // 60}m"))
    if blocked:
        line = (
            color("  ⚠  ATTENTION", "red", bold=True)
            + "   "
            + color(
                ", ".join(f"{r} ({why})" for r, why in blocked),
                "red",
            )
        )
        emit(line)
        emit()

    # (ACTIVE FEATURES section removed — project panes table covers active work)

    # Project panes — table layout
    emit()
    emit(section("PROJECT PANES"))
    if not rows:
        emit(color("  (no project Claudes have reported yet)", "caption", italic=True))
    else:
        # Column widths (responsive)
        repo_w = min(20, max(len(s.get("repo", "?")) for s in rows) + 1)
        age_w = 7
        pr_w = 7
        commits_w = 4
        # Optional workflow badge column (shown if any row has one and width allows)
        any_wf = any(s.get("current_workflow") for s in rows)
        wf_w = 12 if (any_wf and width >= 60) else 0
        # Header row + hairline rule (dot + repo combined into one cell)
        sep = color(" │ ", "rule", dim=True)
        first_w = 2 + repo_w  # "● " + repo
        tasks_w = 10  # done/total + bar
        head_cells = [pad("REPO", first_w)]
        if wf_w:
            head_cells.append(pad("PHASE", wf_w))
        head_cells.extend([
            pad("AGE", age_w, align="right"),
            pad("PR", pr_w, align="right"),
            pad("C", commits_w, align="right"),
            pad("TASKS", tasks_w, align="right"),
        ])
        head_row = "  " + sep.join(
            color(c, "caption", dim=True) for c in head_cells
        )
        emit(head_row)
        total_w = sum(vlen(c) for c in head_cells) + 3 * (len(head_cells) - 1)
        emit(color("  " + "─" * total_w, "rule", dim=True))

        for s in rows:
            repo = s.get("repo", "?")
            age = age_seconds(s.get("last_update", ""))
            age_txt, age_col = fmt_age(age)
            mark, mark_col = pane_state(s, age)
            event = s.get("last_event", "?")
            wf = s.get("current_workflow") or ""
            is_blocked = event in ("Notification", "PermissionRequest")
            fresh = s.get("_fresh")
            repo_col = "alert" if is_blocked else ("accent" if fresh else "head")

            extras = get_pane_extras(repo, extras_cache)
            commits = extras.get("commits_today") or 0
            pr_no = extras.get("pr_number")
            pr_str = f"#{pr_no}" if pr_no else "—"
            commit_str = str(commits) if commits else "—"

            first_cell = (
                color(mark, mark_col) + " "
                + pad(color(repo[:repo_w - 1], repo_col, bold=True), repo_w)
            )
            cells = [first_cell]
            if wf_w:
                wf_text = wf[:wf_w - 1] if wf else "—"
                cells.append(
                    pad(color(wf_text, "caption", italic=bool(wf)), wf_w)
                )
            # Tasks column: done/total
            todos = s.get("todos") or []
            if todos:
                done_n = sum(1 for t in todos if t.get("status") == "completed")
                in_prog_n = sum(1 for t in todos if t.get("status") == "in_progress")
                tasks_str = f"{done_n}/{len(todos)}"
                tasks_col = "good" if done_n == len(todos) else ("accent" if in_prog_n else "caption")
            else:
                tasks_str = "—"
                tasks_col = "caption"
            cells.extend([
                pad(color(age_txt, age_col), age_w, align="right"),
                pad(color(pr_str, "accent" if pr_no else "caption", dim=not pr_no), pr_w, align="right"),
                pad(color(commit_str, "good" if commits else "caption", dim=not commits), commits_w, align="right"),
                pad(color(tasks_str, tasks_col, dim=tasks_str == "—"), tasks_w, align="right"),
            ])
            emit("  " + sep.join(cells))

            # Sub-line: in-progress todo, file, bash, or prompt
            todos = s.get("todos") or []
            in_prog = next((t for t in todos if t.get("status") == "in_progress"), None)
            sub_text: str | None = None
            sub_icon = "└"
            if in_prog:
                sub_text = in_prog.get("activeForm") or in_prog.get("content") or ""
            elif s.get("last_file"):
                p = s["last_file"]
                sub_text = p if len(p) <= width - 10 else "…" + p[-(width - 12):]
                sub_icon = "↳"
            elif s.get("last_bash"):
                sub_text = s["last_bash"]
                sub_icon = "$"
            elif s.get("last_prompt"):
                sub_text = s["last_prompt"]
            if sub_text:
                emit(
                    color(f"     {sub_icon} ", "caption", dim=True)
                    + color(sub_text[: width - 9], "caption")
                )
    emit()

    # Open PRs — one line each
    prs = fetch_open_prs(extras_cache)
    if prs:
        emit()
        emit(section("OPEN PRS", suffix=str(len(prs))))
        num_w = max(len(f"#{p['number']}") for p in prs) + 1
        repo_w = min(22, max(len(p["repo"]) for p in prs) + 2)
        for p in prs:
            draft = p["draft"]
            title_max = max(20, width - 4 - num_w - repo_w - 2)
            title = p["title"][:title_max]
            num_str = color(pad(f"#{p['number']}", num_w), "accent")
            repo_str = color(pad(p["repo"], repo_w), "caption")
            title_str = color(title, "caption" if draft else "head", dim=draft)
            emit(f"  {num_str}{repo_str}{title_str}")

    # Cross-pane todos
    emit()
    emit(section("TODOS"))
    emit(section_rule(width))
    emit()
    todos_flat: list[tuple[str, str, str]] = []
    for s in rows:
        for t in s.get("todos") or []:
            todos_flat.append(
                (
                    t.get("status", "pending"),
                    s.get("repo", "?"),
                    t.get("activeForm") or t.get("content", ""),
                )
            )
    if not todos_flat:
        emit(color("    (no task snapshots yet — fires on TaskCreate / TaskUpdate)", "gray", dim=True))
    else:
        order = {"in_progress": 0, "pending": 1, "completed": 2}
        todos_flat.sort(key=lambda r: (order.get(r[0], 9), r[1]))
        for status, repo, content in todos_flat:
            mark = STATUS_MARK.get(status, "?")
            if status == "in_progress":
                mark_col, text_col = "yellow", "white"
            elif status == "completed":
                mark_col, text_col = "green", "gray"
            else:
                mark_col, text_col = "gray", "white"
            line = (
                f"  {color('[' + mark + ']', mark_col)} "
                f"{color(repo, 'cyan'):<{26 + 8}}"
                f"{color(content[: width - 35], text_col)}"
            )
            emit(line)
    emit()

    # Event stream
    emit()
    emit(section("EVENT STREAM"))
    emit(section_rule(width))
    emit()
    if not events_log:
        emit(color("    (no events recorded yet)", "gray", dim=True))
    else:
        repo_colors = ["cyan", "magenta", "yellow", "green", "red"]
        repo_color_map: dict[str, str] = {}
        recent = events_log[-4:]
        for e in recent:
            ts = e.get("ts", "")
            try:
                hhmm = datetime.fromisoformat(ts).strftime("%H:%M:%S")
            except (TypeError, ValueError):
                hhmm = ts[:8]
            repo = e.get("repo", "?")
            if repo not in repo_color_map:
                repo_color_map[repo] = repo_colors[len(repo_color_map) % len(repo_colors)]
            line = (
                f"  {color(hhmm, 'gray', dim=True)}  "
                f"{color(repo, repo_color_map[repo]):<{20 + 8}}"
                f"{color(e.get('event', '?'), 'magenta'):<{18 + 8}}"
                f"{color(e.get('tool') or '', 'yellow')}"
            )
            emit(line)
    emit()

    # Footer — Spotify visualizer (full width, color per song)
    emit()
    emit(section_rule(width))
    emit()
    import math
    import random as _rand

    cache_dir = _config().cache_dir
    cache_dir.mkdir(parents=True, exist_ok=True)
    eq_path = cache_dir / "eq.txt"
    frame = (_read_counter(eq_path) + 1) % 1000
    _write_counter(eq_path, frame)

    playing, track = spotify_state()
    bars_n = max(20, width - 6)  # full width minus margin + ♪ prefix

    # Pick a stable hue per track via simple hash → 256-color palette
    song_palette = [
        ("good", 108, 78),     # sage variants
        ("accent", 215, 209),  # amber → coral
        (None, 81, 117),       # cyan / mint
        (None, 141, 99),       # lavender / purple
        (None, 207, 213),      # magenta / pink
        (None, 220, 178),      # yellow / mustard
        (None, 196, 202),      # red / orange
        (None, 51, 39),        # bright cyan / teal
        (None, 156, 47),       # mint / green
        (None, 183, 177),      # lilac / plum
    ]

    def _song_codes(t: str | None) -> tuple[int, int]:
        if not t:
            return (108, 78)
        h = sum(ord(c) for c in t)
        _, primary, accent_c = song_palette[h % len(song_palette)]
        return (primary, accent_c)

    primary_code, accent_code = _song_codes(track)

    def _fg(code: int) -> str:
        return f"{ESC}38;5;{code}m"

    if playing:
        # Sine wave + jitter + per-track frequency shift for "alive" feel
        _rand.seed(frame)
        # Track-derived frequency for visual signature per song
        freq = 0.4 + (sum(ord(c) for c in (track or "")) % 7) * 0.1
        bars = []
        for i in range(bars_n):
            base = (math.sin(frame / 3 + i * freq) + 1) / 2
            jitter = _rand.random() * 0.25
            v = min(1.0, base * 0.85 + jitter)
            idx = min(len(SPARK_CHARS) - 1, int(v * (len(SPARK_CHARS) - 1)))
            # Alternate primary / accent shade across bars for richness
            ch = SPARK_CHARS[idx]
            shade = primary_code if (i % 3) != 0 else accent_code
            bars.append(f"{BOLD}{_fg(shade)}{ch}{RESET}")
        bar_line = "".join(bars)
        emit("  " + f"{BOLD}{_fg(accent_code)}♪ {RESET}" + bar_line)
        if track:
            # Track title in the song's accent color so it stays readable + varies per track
            emit("    " + f"{ITALIC}{_fg(accent_code)}{track[: width - 6]}{RESET}")
    else:
        emit("  " + color("♪ ", "caption", dim=True) + color("▁" * bars_n, "caption", dim=True))
        emit("    " + color("Spotify paused" if track else "Spotify offline", "caption", italic=True, dim=True))

    emit()
    emit(color("  Ctrl-C to exit", "caption", italic=True))

    save_pane_extras_cache(extras_cache)
    flush_frame()


def main() -> None:
    global _CONFIG
    try:
        _CONFIG = load_config()
    except ConfigError as exc:
        sys.exit(f"pa.dashboard_render: {exc}")
    render(_CONFIG.state_dir)


if __name__ == "__main__":
    main()
