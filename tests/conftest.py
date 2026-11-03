"""Shared browser fixture for replay and complete hosted-game workflows."""

import functools
import json
import os
import shutil
import subprocess
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def native_controls():
    def present(frame):
        before = frame.evaluate("Module.replayFrameCount")
        frame.wait_for_function("before => Module.replayFrameCount >= before + 2", arg=before)

    def key(page, frame, button):
        page.keyboard.down(button)
        present(frame)
        page.keyboard.up(button)
        present(frame)

    def click(page, frame, x, y):
        page.mouse.move(x, y)
        present(frame)
        page.mouse.down()
        present(frame)
        page.mouse.up()
        present(frame)

    return key, click


@pytest.fixture
def viewer(tmp_path, request):
    from playwright.sync_api import sync_playwright

    bundle = tmp_path / "viewer"
    native = getattr(request, "param", "jax") == "polyworld"
    hook = "build_replay_viewer.sh" if native else "build_legacy_replay_viewer.sh"
    subprocess.run([str(ROOT / "integrations/softmax/tools" / hook), str(bundle)], check=True)

    class Handler(SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            if self.path.startswith("/client/player?"):
                self.path = "/index.html"
            elif self.path.startswith("/client/static/"):
                self.path = self.path.removeprefix("/client/static")
            super().do_GET()

        def end_headers(self):
            if native:
                from polyworld.tools.check_browser import CSP

                self.send_header("Content-Security-Policy", CSP)
            super().end_headers()

    http = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=bundle))
    threading.Thread(target=http.serve_forever, daemon=True).start()
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(
                executable_path=os.environ.get("CHROMIUM_PATH") or shutil.which("chromium"),
                args=["--no-sandbox"],
            )
            page = browser.new_page(viewport={"width": 1100, "height": 1000})
            if not native:
                page.clock.install(time=0)
                page.clock.pause_at(1)
            errors = []
            page.on("pageerror", lambda error: errors.append(str(error)))
            yield page, f"http://127.0.0.1:{http.server_port}", bundle
            assert not errors
            browser.close()
    finally:
        http.shutdown()
        http.server_close()


@pytest.fixture
def inspect_native_replay():
    def inspect(path):
        result = subprocess.run(
            [os.environ["GENERALS_POLYWORLD_ENGINE"], "--inspect-replay", str(path)],
            check=True, capture_output=True, text=True, timeout=60,
        )
        return json.loads(result.stdout)
    return inspect
