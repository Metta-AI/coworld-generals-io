"""Public hosted sessions protect construction, fog, receipts and replay persistence."""

import json
import os
from contextlib import ExitStack

import pytest
from fastapi.testclient import TestClient

from competition.agents.expander_python.agent import Agent
from integrations.softmax.builder_player import choose_action
from integrations.softmax.config import GameConfig
from integrations.softmax.protocol import PASS
from integrations.softmax.replay import replay_frame
from integrations.softmax.server import create_app


def test_polyworld_builders_finish_and_replay_their_constructed_castles(tmp_path):
    if "GENERALS_POLYWORLD_ENGINE" not in os.environ:
        pytest.skip("Compile polyworld_bridge.nim and set GENERALS_POLYWORLD_ENGINE")
    config = GameConfig(tokens=["red", "blue"], players=[{"name": "Red"}, {"name": "Blue"}],
                        seed=7, ruleset="build_castles", max_turns=140, turn_timeout_seconds=1)
    artifacts = {key: (tmp_path / f"{key}.json").as_uri() for key in ("results", "replay", "failure")}
    built = []
    with TestClient(create_app(config, artifacts, engine="polyworld")) as client, ExitStack() as stack:
        sockets = [stack.enter_context(client.websocket_connect(f"/player?slot={s}&token={token}"))
                   for s, token in enumerate(config.tokens)]
        hello = [ws.receive_json() for ws in sockets]
        agents = [Agent(s, h["height"], h["width"]) for s, h in enumerate(hello)]
        previous = [PASS, PASS]
        for turn in range(config.max_turns):
            for slot, ws in enumerate(sockets):
                observation = ws.receive_json()
                assert observation["turn"] == turn
                assert any(0 in row for row in observation["type_grid"]), "opposing maps must stay hidden"
                if observation["last_build_executed"]:
                    built.append((turn, slot, previous[slot][1], previous[slot][2]))
                action = choose_action(observation, agents[slot])
                ws.send_json({"type": "action", "turn": turn, "action": action})
                previous[slot] = action
        result = sockets[0].receive_json()["result"]
        assert result["turns"] == 140 and result["timeouts"] == [0, 0]
        replay = client.get("/replay.json").json()
    assert len({slot for _, slot, _, _ in built}) == 2
    saved = json.loads((tmp_path / "replay.json").read_text())
    assert saved["format"] == "polyworld-generals-hosted" and saved["result"] == result
    assert len(saved["ticks"]) == 141 and "frames" not in saved
    assert replay["engine"] == "polyworld"
    for turn, slot, row, col in built:
        frame = replay_frame(replay["frames"], turn)
        assert frame["type_grid"][row][col] == 3 and frame["owner_grid"][row][col] == slot + 1
    assert not (tmp_path / "failure.json").exists()


def test_polyworld_final_surrenders_persist_one_terminal_tick(tmp_path):
    if "GENERALS_POLYWORLD_ENGINE" not in os.environ:
        pytest.skip("Compile polyworld_bridge.nim and set GENERALS_POLYWORLD_ENGINE")
    config = GameConfig(tokens=["red", "blue", "green"],
                        players=[{"name": name} for name in ("Red", "Blue", "Green")],
                        seed=1, max_turns=10, turn_timeout_seconds=1)
    artifacts = {key: (tmp_path / f"{key}.json").as_uri() for key in ("results", "replay", "failure")}
    with TestClient(create_app(config, artifacts, engine="polyworld")) as client, ExitStack() as stack:
        sockets = [stack.enter_context(client.websocket_connect(f"/player?slot={s}&token={token}"))
                   for s, token in enumerate(config.tokens)]
        for ws in sockets:
            assert ws.receive_json()["type"] == "hello"
            assert ws.receive_json()["turn"] == 0
        sockets[0].send_json({"type": "surrender"})
        sockets[1].send_json({"type": "surrender"})
        sockets[2].send_json({"type": "action", "turn": 0, "action": PASS})
        result = sockets[2].receive_json()["result"]
        replay = client.get("/replay.json").json()
    assert result["winner"] == 2 and result["turns"] == 1
    assert result == json.loads((tmp_path / "results.json").read_text())
    assert [replay_frame(replay["frames"], i)["turn"] for i in range(2)] == [0, 1]


@pytest.mark.parametrize("viewer", ["polyworld"], indirect=True)
@pytest.mark.parametrize("variant,count,turns", [("ffa", 8, 80), ("castles", 2, 140)])
@pytest.mark.skipif(
    os.environ.get("GENERALS_BROWSER_TESTS") != "1" or
    "GENERALS_POLYWORLD_ENGINE" not in os.environ or "GENERALS_POLYWORLD_VIEWER" not in os.environ,
    reason="requires the compiled Polyworld engine/viewer and the real browser suite",
)
def test_polyworld_tapes_verify_seek_and_reject_divergence(tmp_path, viewer, variant, count, turns, native_controls):
    """A shipped replay must reproduce hosted rules in the actual WASM viewer."""
    import gzip
    import socket
    import subprocess
    import sys
    from pathlib import Path

    key, click = native_controls

    page, base, bundle = viewer
    page.set_viewport_size({"width": 1280, "height": 900})
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    root = Path(__file__).resolve().parents[2]
    subprocess.run(
        [sys.executable, "-m", "integrations.softmax.local", "--variant", variant,
         *(["--players", str(count)] if variant == "ffa" else []), "--seed", "4294967295", "--max-turns", str(turns),
         "--port", str(port), "--output", str(tmp_path / "episodes")],
        cwd=root, check=True, capture_output=True, text=True, timeout=180,
    )
    recording = next((tmp_path / "episodes").glob("episode-*/replay.json"))
    tape = json.loads(recording.read_text())
    assert tape["format"] == "polyworld-generals-hosted" and "frames" not in tape
    assert tape["result"]["timeouts"] == [0] * count
    (bundle / "replay.gz").write_bytes(gzip.compress(recording.read_bytes()))
    page.goto(base + "/#replay=replay.gz")
    page.wait_for_function("() => failed || typeof Module.replayTick === 'number'", timeout=60000)
    assert not page.evaluate("failed"), page.locator("#status-detail").inner_text()
    page.wait_for_function("() => failed || Module.replayTick >= 1", timeout=60000)
    assert not page.evaluate("failed"), page.locator("#status-detail").inner_text()
    click(page, page, 200, 200)
    click(page, page, 420, 860)
    page.wait_for_function("() => !Module.replayRepeating")
    key(page, page, "End")
    page.wait_for_function(f"() => failed || Module.replayTick === {tape['result']['turns']}")
    assert not page.evaluate("failed"), page.locator("#status-detail").inner_text()
    page.screenshot(path=str(tmp_path / f"native-{variant}-desktop.png"))
    page.set_viewport_size({"width": 390, "height": 844})
    page.wait_for_function("() => Module.canvas.width === 390 && Module.canvas.height === 844")
    page.screenshot(path=str(tmp_path / f"native-{variant}-mobile.png"))
    key(page, page, "Home")
    key(page, page, "ArrowRight")
    page.wait_for_function("() => Module.replayTick === 1")
    assert not page.evaluate("failed")
    tape["ticks"][1][0]["hash"] = "0000000000000000"
    (bundle / "divergent.json").write_text(json.dumps(tape))
    page.goto(base + "/?divergent=1#replay=divergent.json")
    page.wait_for_function("() => failed", timeout=60000)
    assert "diverged" in page.locator("#status-detail").inner_text()
