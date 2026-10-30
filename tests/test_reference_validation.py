"""Complete reference export/comparison flow; requires privately supplied real core files."""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
ENGINE = os.environ.get("GENERALS_REFERENCE_ENGINE")
pytestmark = pytest.mark.skipif(
    not ENGINE, reason="set GENERALS_REFERENCE_ENGINE to the external replay-core directory"
)


def test_reference_export_compares_games_and_rejects_incomplete_recording(tmp_path):
    fixtures = ROOT / "tests/fixtures/reference_replays"
    boards = tmp_path / "boards"
    subprocess.run(
        [
            sys.executable,
            "paper/validation/reference_boards.py",
            ENGINE,
            str(fixtures / "synthetic-*.gior"),
            str(boards),
        ],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    report = tmp_path / "comparison.json"
    subprocess.run(
        [
            sys.executable,
            "paper/validation/ffa/board_diff_ffa.py",
            str(boards),
            str(fixtures / "synthetic-*.gior"),
            "--np",
            "4",
            "--out",
            str(report),
        ],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
        timeout=180,
    )
    results = json.loads(report.read_text())
    assert len(results) == 2
    for result in results:
        assert "excluded" not in result
        assert result["engine_afk"]["mismatch_ticks"] == 0
        assert result["engine_afk"]["same_end"]
        assert not result["engine_afk"]["terminal_mismatch"]
        snapshot = json.loads((boards / f"{result['id']}.json").read_text())
        assert len(snapshot["owners"]) == snapshot["turns"] + 1
        assert len(snapshot["reference_sources_sha256"]) == 4
        assert len(snapshot["replay_sha256"]) == 64
    incomplete_output = tmp_path / "incomplete"
    rejected = subprocess.run(
        [
            sys.executable,
            "paper/validation/reference_boards.py",
            ENGINE,
            str(fixtures / "incomplete.gior"),
            str(incomplete_output),
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=130,
    )
    assert rejected.returncode != 0
    assert "No terminal outcome" in rejected.stderr
    assert not list(incomplete_output.glob("*.json"))
