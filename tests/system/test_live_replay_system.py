"""Keep a completed match watchable after the hosted HTTP proxy retires."""

import json
import os
import re
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


def test_live_players_and_spectators_keep_replay_after_http_proxy_retires(tmp_path):
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    config = {
        "tokens": ["human", "bot"], "players": [{"name": "Human"}, {"name": "Bot"}],
        "seed": 7, "max_turns": 12, "turn_timeout_seconds": 1, "tick_interval_seconds": 0.05,
    }
    (tmp_path / "config.json").write_text(json.dumps(config))
    script = '''
import sys
from pathlib import Path
import uvicorn
from fastapi.responses import JSONResponse
from integrations.softmax.config import GameConfig
from integrations.softmax.server import create_app
root = Path(sys.argv[1])
app = create_app(GameConfig.model_validate_json((root / "config.json").read_text()),
                 {key: (root / (key + ".json")).as_uri() for key in ("results", "replay", "failure")})
@app.middleware("http")
async def retired_proxy(request, call_next):
    if (root / "results.json").exists():
        return JSONResponse({"detail": "Game is not accepting connections"}, status_code=410)
    return await call_next(request)
uvicorn.run(app, host="127.0.0.1", port=int(sys.argv[2]), log_level="error")
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
                        bot = subprocess.Popen([sys.executable, "-m", "integrations.softmax.player"], cwd=ROOT,
                            env={**os.environ, "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot=1&token=bot"},
                            stdout=log, stderr=subprocess.STDOUT)
                        for page in (player, spectator):
                            expect(page.locator("#mode")).to_have_text("REPLAY", timeout=30000)
                            expect(page.locator("#board .tile").first).to_be_visible()
                        assert client.get(base + "/client/replay.json").status_code == 410
                        assert json.loads((tmp_path / "results.json").read_text())["timeouts"] == [0, 0]
                        bot.wait(timeout=10)
                        assert bot.returncode == 0
                        server.terminate()
                        server.wait(timeout=10)
                        for page in (player, spectator):
                            page.get_by_role("button", name="Pause", exact=True).click()
                            page.locator("#seek").fill("12")
                            expect(page.locator("#turn")).to_have_text("12")
                            expect(page.locator("#download-replay")).to_have_attribute("href", re.compile("^blob:"))
                    finally:
                        browser.close()
        finally:
            for process in (bot, server):
                if process is not None and process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
