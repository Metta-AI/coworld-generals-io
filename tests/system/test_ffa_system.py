"""An eight-seat episode must finish and remain watchable on ranked-size maps."""

import json
import os
import socket
import subprocess
import sys
from pathlib import Path

import pytest

if os.environ.get("GENERALS_BROWSER_TESTS") != "1":
    pytest.skip("requires the real browser suite", allow_module_level=True)

from playwright.sync_api import expect

ROOT = Path(__file__).resolve().parents[2]


def test_eight_bots_finish_and_replay_on_desktop_and_mobile(tmp_path, viewer):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    output = tmp_path / "episodes"
    subprocess.run(
        [sys.executable, "-m", "integrations.softmax.local", "--variant", "ffa", "--players", "8",
         "--seed", "42", "--max-turns", "80", "--port", str(port), "--output", str(output)],
        cwd=ROOT, check=True, capture_output=True, text=True, timeout=180,
    )
    recording = next(output.glob("episode-*/replay.json"))
    replay = json.loads(recording.read_text())
    assert replay["result"]["timeouts"] == [0] * 8
    assert len(replay["players"]) == 8
    assert 25 <= replay["height"] <= 33 and 25 <= replay["width"] <= 33
    assert set(value for row in replay["frames"][0]["owner_grid"] for value in row) == set(range(9))

    page, base, bundle = viewer
    (bundle / "replay.json").write_bytes(recording.read_bytes())
    page.goto(f"{base}/#replay=replay.json")
    expect(page.locator("#mode")).to_have_text("REPLAY")
    expect(page.locator(".player")).to_have_count(8)
    expect(page.locator("#perspective option")).to_have_count(9)
    expect(page.locator("#board .tile")).to_have_count(replay["height"] * replay["width"])
    assert len(set(page.locator("#board .has-general").evaluate_all(
        "tiles => tiles.map(tile => getComputedStyle(tile).backgroundColor)"
    ))) == 8
    page.locator("#perspective").select_option("7")
    expect(page.locator("#board .fog").first).to_be_visible()
    page.locator("#seek").fill(str(len(replay["frames"]) - 1))
    expect(page.locator("#turn")).to_have_text(str(replay["result"]["turns"]))

    page.set_viewport_size({"width": 390, "height": 844})
    page.locator("#seek").fill("0")
    page.locator("#perspective").select_option("all")
    board = page.locator("#board").bounding_box()
    assert board["width"] > 0 and board["x"] >= 0 and board["x"] + board["width"] <= 390
    assert page.locator("#name7").bounding_box()["y"] < board["y"]
