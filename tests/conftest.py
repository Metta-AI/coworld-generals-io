"""Shared browser fixture for replay and complete hosted-game workflows."""

import functools
import os
import shutil
import subprocess
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def viewer(tmp_path):
    from playwright.sync_api import sync_playwright

    bundle = tmp_path / "viewer"
    subprocess.run([str(ROOT / "integrations/softmax/tools/build_replay_viewer.sh"), str(bundle)], check=True)

    class Handler(SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            if self.path.startswith("/client/player?"):
                self.path = "/index.html"
            elif self.path.startswith("/client/static/"):
                self.path = self.path.removeprefix("/client/static")
            super().do_GET()

    http = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=bundle))
    threading.Thread(target=http.serve_forever, daemon=True).start()
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(
                executable_path=os.environ.get("CHROMIUM_PATH") or shutil.which("chromium"),
                args=["--no-sandbox"],
            )
            page = browser.new_page(viewport={"width": 1100, "height": 1000})
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

