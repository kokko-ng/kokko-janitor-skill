"""Tests for plugins/kokko-janitor/hooks/progress-guard.sh, run as a subprocess."""

import json
import os
import subprocess
import time
from pathlib import Path

HOOK = (
    Path(__file__).resolve().parents[1]
    / "plugins"
    / "kokko-janitor"
    / "hooks"
    / "progress-guard.sh"
)


def run_hook(cwd, payload=None, env=None, raw=None):
    """Run the hook with a Stop payload for `cwd`; the state dir is per test."""
    if raw is None:
        data = {"cwd": str(cwd), "hook_event_name": "Stop", "stop_hook_active": False}
        data.update(payload or {})
        raw = json.dumps(data)
    state = cwd / "hook-tmp"
    state.mkdir(exist_ok=True)
    full_env = {**os.environ, "TMPDIR": str(state)}
    full_env.pop("KOKKO_PROGRESS_GUARD", None)
    full_env.update(env or {})
    return subprocess.run(
        ["bash", str(HOOK)],
        input=raw,
        capture_output=True,
        text=True,
        cwd=cwd,
        env=full_env,
        check=False,
    )


def write_progress(cwd, lines, name="local-validation-progress.md"):
    path = cwd / "prompts" / name
    path.parent.mkdir(exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def decision(proc):
    assert proc.returncode == 0, proc.stderr
    assert proc.stderr == ""
    return json.loads(proc.stdout) if proc.stdout.strip() else None


def test_no_prompts_dir_is_silent(tmp_path):
    assert decision(run_hook(tmp_path)) is None


def test_open_items_block_once_then_stay_silent_until_the_file_changes(tmp_path):
    path = write_progress(
        tmp_path,
        ["US-001 | passed | ok", "US-002 | pending | todo", "US-003 | in-progress | x"],
    )
    first = decision(run_hook(tmp_path))
    assert first["decision"] == "block"
    assert "prompts/local-validation-progress.md" in first["reason"]
    assert "2 open item(s)" in first["reason"]
    # Same content again: the loop breaker lets the stop through.
    assert decision(run_hook(tmp_path)) is None
    # Progress happened: the guard blocks again, with the new count.
    path.write_text(path.read_text() + "US-002 | passed | done\n", encoding="utf-8")
    again = decision(run_hook(tmp_path))
    assert again["decision"] == "block"
    assert "2 open item(s)" in again["reason"]  # US-002 is listed twice now


def test_all_passed_or_blocked_is_silent(tmp_path):
    write_progress(
        tmp_path,
        ["US-001 | passed | ok", "US-002 | blocked | needs creds", "US-003 | passed |"],
    )
    assert decision(run_hook(tmp_path)) is None


def test_aesthetics_open_defects_count(tmp_path):
    write_progress(
        tmp_path,
        ["D-001 | fixed | login | 1280 | ok", "D-002 | open | login | 375 | clipped"],
        name="aesthetics-progress.md",
    )
    result = decision(run_hook(tmp_path))
    assert result["decision"] == "block"
    assert "aesthetics-progress.md" in result["reason"]
    assert "1 open item(s)" in result["reason"]


def test_stale_file_is_ignored(tmp_path):
    path = write_progress(tmp_path, ["US-001 | pending | todo"])
    old = time.time() - 2 * 60 * 60
    os.utime(path, (old, old))
    assert decision(run_hook(tmp_path)) is None


def test_env_off_disables_the_guard(tmp_path):
    write_progress(tmp_path, ["US-001 | pending | todo"])
    assert decision(run_hook(tmp_path, env={"KOKKO_PROGRESS_GUARD": "off"})) is None


def test_files_outside_prompts_are_ignored(tmp_path):
    (tmp_path / "notes-progress.md").write_text("US-001 | pending | x\n")
    (tmp_path / "prompts").mkdir()
    assert decision(run_hook(tmp_path)) is None


def test_malformed_stdin_falls_back_to_the_working_directory(tmp_path):
    write_progress(tmp_path, ["US-001 | pending | todo"])
    result = decision(run_hook(tmp_path, raw="this is not json"))
    assert result["decision"] == "block"


def test_subagent_stop_uses_the_same_rules(tmp_path):
    write_progress(tmp_path, ["US-001 | in-progress | x"])
    result = decision(run_hook(tmp_path, payload={"hook_event_name": "SubagentStop"}))
    assert result["decision"] == "block"
