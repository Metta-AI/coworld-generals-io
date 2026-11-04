"""Completed games show their winner before automatic replay loops resume."""

import os
import time
from contextlib import ExitStack

import pytest
from fastapi.testclient import TestClient

from integrations.softmax.config import GameConfig
from integrations.softmax.protocol import PASS
from integrations.softmax.server import create_app


@pytest.mark.parametrize("viewer", ["polyworld"], indirect=True)
@pytest.mark.skipif(
    os.environ.get("GENERALS_BROWSER_TESTS") != "1"
    or "GENERALS_POLYWORLD_ENGINE" not in os.environ
    or "GENERALS_POLYWORLD_VIEWER" not in os.environ,
    reason="requires the real engine and WebAssembly browser viewer",
)
def test_winner_screen_holds_loop_and_respects_pause_and_rewind(tmp_path, viewer, native_controls):
    """A real winning episode pauses at its final verified tick for five seconds."""
    config = GameConfig(
        tokens=["red", "blue", "winner"],
        players=[{"name": name} for name in ("Red", "Blue", "Foo Bot")],
        seed=1, max_turns=10, turn_timeout_seconds=1,
    )
    artifacts = {key: (tmp_path / f"{key}.json").as_uri()
                 for key in ("results", "replay", "failure")}
    with TestClient(create_app(config, artifacts, engine="polyworld")) as client, ExitStack() as stack:
        sockets = [stack.enter_context(client.websocket_connect(f"/player?slot={slot}&token={token}"))
                   for slot, token in enumerate(config.tokens)]
        for ws in sockets:
            assert ws.receive_json()["type"] == "hello"
            assert ws.receive_json()["turn"] == 0
        sockets[0].send_json({"type": "surrender"})
        sockets[1].send_json({"type": "surrender"})
        sockets[2].send_json({"type": "action", "turn": 0, "action": PASS})
        result = sockets[2].receive_json()["result"]
        assert result["winner"] == 2 and result["turns"] == 1

    page, base, bundle = viewer
    key, click = native_controls
    (bundle / "winner.replay").write_bytes((tmp_path / "replay.json").read_bytes())
    page.set_viewport_size({"width": 1280, "height": 900})
    page.goto(base + "/#replay=winner.replay")
    page.wait_for_function("() => failed || Module.replayOutcome === 'Foo Bot wins the game!'", timeout=60000)
    assert not page.evaluate("failed"), page.locator("#status-detail").inner_text()
    shown = time.monotonic()
    assert page.evaluate("Module.replayTick") == 1
    assert page.evaluate("Module.replayPlaying && Module.replayRepeating")
    page.screenshot(path=str(tmp_path / "winner-screen.png"))
    page.wait_for_timeout(4400)
    assert page.evaluate("Module.replayTick") == 1
    assert page.evaluate("Module.replayOutcome") == "Foo Bot wins the game!"
    page.wait_for_function("() => Module.replayTick === 0 && Module.replayOutcome === ''", timeout=2000)
    assert time.monotonic() - shown >= 4.9

    page.wait_for_function("() => Module.replayTick === 1")
    key(page, page, "Space")
    assert not page.evaluate("Module.replayPlaying")
    page.wait_for_timeout(5100)
    assert page.evaluate("Module.replayTick") == 1
    assert page.evaluate("Module.replayOutcome") == "Foo Bot wins the game!"
    key(page, page, "Home")
    page.wait_for_function("() => Module.replayTick === 0 && Module.replayOutcome === ''")

    click(page, page, 420, 860)
    assert not page.evaluate("Module.replayRepeating")
    key(page, page, "End")
    page.wait_for_function("() => Module.replayTick === 1 && !Module.replayPlaying")
    assert page.evaluate("Module.replayOutcome") == "Foo Bot wins the game!"
    key(page, page, "ArrowLeft")
    page.wait_for_function("() => Module.replayTick === 0 && !Module.replayPlaying")
    assert page.evaluate("Module.replayOutcome") == ""
