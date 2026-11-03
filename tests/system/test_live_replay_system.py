"""Keep a completed match watchable after the hosted HTTP proxy retires."""

import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

import httpx
import pytest

if os.environ.get("GENERALS_BROWSER_TESTS") != "1":
    pytest.skip("requires the real browser suite", allow_module_level=True)

from playwright.sync_api import expect, sync_playwright

ROOT = Path(__file__).resolve().parents[2]


def test_live_players_and_spectators_keep_replay_after_http_proxy_retires(tmp_path, native_controls):
    native = os.environ.get("GENERALS_ENGINE") == "polyworld"
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    config = {
        "tokens": ["human", "bot"], "players": [{"name": "Human"}, {"name": "Bot"}],
        "player_ratings": {"league": "Fixture FFA", "label": "MMR", "players": [{"slot": 0, "score": -2.34}, {"slot": 1, "score": 27.38}]},
        "seed": 7, "max_turns": 12, "turn_timeout_seconds": 1, "tick_interval_seconds": 0.05,
    }
    (tmp_path / "config.json").write_text(json.dumps(config))
    script = '''
import sys
from pathlib import Path
import uvicorn
from urllib.parse import parse_qsl, urlencode
from fastapi.responses import JSONResponse
from integrations.softmax.config import GameConfig
from integrations.softmax.server import create_app
root = Path(sys.argv[1])
app = create_app(GameConfig.model_validate_json((root / "config.json").read_text()),
                 {key: (root / (key + ".json")).as_uri() for key in ("results", "replay", "failure")},
                 shutdown=lambda: setattr(server, "should_exit", True))
@app.middleware("http")
async def retired_proxy(request, call_next):
    if (root / "results.json").exists():
        return JSONResponse({"detail": "Game is not accepting connections"}, status_code=410)
    return await call_next(request)
class SeatQueryOnly:
    def __init__(self, app):
        self.app = app
    async def __call__(self, scope, receive, send):
        if scope["type"] == "websocket":
            # The hosted Kubernetes hop can drop optional URL query fields.
            scope = {**scope, "query_string": urlencode([
                (key, value) for key, value in parse_qsl(scope["query_string"].decode())
                if key in {"slot", "token"}
            ]).encode()}
        await self.app(scope, receive, send)
app.add_middleware(SeatQueryOnly)
server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=int(sys.argv[2]), log_level="error"))
server.run()
'''
    with (tmp_path / "server.log").open("w") as log:
        server = subprocess.Popen([sys.executable, "-c", script, str(tmp_path), str(port)], cwd=ROOT,
                                  stdout=log, stderr=subprocess.STDOUT)
        bot = None
        try:
            base = f"http://127.0.0.1:{port}"
            with httpx.Client() as client:
                deadline = time.monotonic() + 60
                while True:
                    assert server.poll() is None, (tmp_path / "server.log").read_text()
                    if time.monotonic() > deadline:
                        pytest.fail("game did not start")
                    with socket.socket() as probe:
                        if probe.connect_ex(("127.0.0.1", port)) == 0:
                            break
                    time.sleep(0.05)
                assert client.get(base + "/healthz").status_code == 200
                with sync_playwright() as playwright:
                    browser = playwright.chromium.launch()
                    try:
                        player = browser.new_page()
                        spectator = browser.new_page()
                        player.goto(base + "/client/player?slot=0&token=human")
                        spectator.goto(base + "/client/global")
                        expect(player.locator("#mode")).to_have_text("PLAYER")
                        expect(spectator.locator("#mode")).to_have_text("LIVE")
                        for page in (player, spectator):
                            expect(page.locator("#skill0")).to_have_text("★ -2.3")
                            expect(page.locator("#skill1")).to_have_text("★ 27.4")
                        bot = subprocess.Popen([sys.executable, "-m", "integrations.softmax.player"], cwd=ROOT,
                            env={**os.environ, "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot=1&token=bot"},
                            stdout=log, stderr=subprocess.STDOUT)
                        for page in (player, spectator):
                            if native:
                                expect(page.locator("#polyworld-replay")).to_be_visible(timeout=30000)
                                frame = page.frames[1]
                                frame.wait_for_function("() => typeof Module.replayTick === 'number' || failed")
                                assert not frame.evaluate("failed"), frame.locator("#status-detail").inner_text()
                                assert frame.evaluate("Module.replaySkillScores") == ["-2.3", "27.4"]
                            else:
                                expect(page.locator("#mode")).to_have_text("REPLAY", timeout=30000)
                                expect(page.locator("#board .tile").first).to_be_visible()
                        assert json.loads((tmp_path / "results.json").read_text())["timeouts"] == [0, 0]
                        bot.wait(timeout=10)
                        assert bot.returncode == 0
                        server.wait(timeout=10)
                        assert server.returncode == 0
                        for page in (player, spectator):
                            if native:
                                frame = page.frames[1]
                                key, click = native_controls
                                click(page, frame, 200, 200)
                                click(page, frame, 336, 688)
                                frame.wait_for_function("() => !Module.replayRepeating")
                                key(page, frame, "End")
                                frame.wait_for_function("() => Module.replayTick === 12")
                                assert not frame.evaluate("failed")
                                with page.expect_download() as saved:
                                    frame.get_by_role("link", name="Download replay").click()
                                assert json.loads(Path(saved.value.path()).read_text()) == json.loads(
                                    (tmp_path / "replay.json").read_text())
                                continue
                            page.get_by_role("button", name="Pause", exact=True).click()
                            page.locator("#seek").fill("12")
                            expect(page.locator("#turn")).to_have_text("6")
                            with page.expect_download() as saved:
                                page.get_by_role("link", name="Download replay", exact=True).click()
                            assert json.loads(Path(saved.value.path()).read_text()) == json.loads(
                                (tmp_path / "replay.json").read_text())
                    finally:
                        browser.close()
        finally:
            for process in (bot, server):
                if process is not None and process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
