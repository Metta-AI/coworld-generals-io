"""Check the static replay viewer in a real browser under CoWorld's CSP."""

import argparse
import gzip
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import struct
import threading
from urllib.parse import quote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
CSP = (
    "default-src 'none'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; "
    "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: https:; "
    "font-src 'self' data:; connect-src 'self' https: http:; "
    "media-src 'self' blob:; worker-src 'self' blob:; frame-src 'self'"
)
CHAT_ERRORS = {
    "chat_count": "decoded chat count exceeds the recording limit",
    "chat_truncated": "decoded chat entries exceed the remaining payload",
    "chat_text": "decoded chat text exceeds the byte limit",
}
PROBE = b"""<!doctype html>
<meta charset="utf-8"><title>Generals replay acceptance probe</title>
<style>html,body,iframe{margin:0;width:100%;height:100%;border:0;
overflow:hidden}</style><iframe name="viewer" title="Replay"></iframe>
<script>
window.replayMessages = [];
const frame = document.querySelector('iframe');
window.addEventListener('message', event => {
  if (event.source !== frame.contentWindow ||
      event.data?.src !== 'coworld-replay') return;
  const entry = {...event.data};
  if (entry.type === 'ready') entry.tick = frame.contentWindow.Module?.replayTick;
  replayMessages.push(entry);
});
frame.src = new URLSearchParams(location.search).get('viewer');
</script>"""


class Handler(SimpleHTTPRequestHandler):
    """Serve the untouched bundle and local replay fixtures with hosted headers."""

    def do_GET(self):
        """Return in-memory fixtures or a file from the static bundle."""
        path = urlsplit(self.path).path
        fixtures = self.server.fixtures
        if path in fixtures:
            content_type, content = fixtures[path]
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        elif path.startswith("/_fixture/"):
            self.send_error(404, "Replay fixture not found")
        else:
            super().do_GET()

    def end_headers(self):
        """Apply the same browser restrictions as CoWorld's local viewer."""
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, _format, *_args):
        """Keep expected fixture errors out of the acceptance report."""


def assert_healthy(frame):
    """Fail with the viewer's visible diagnostics when simulation diverges."""
    assert not frame.evaluate("failed"), frame.locator("#status").inner_text()


def key(page, value):
    """Hold a physical key across a frame in software-rendered browsers."""
    page.keyboard.down(value)
    page.wait_for_timeout(100)
    page.keyboard.up(value)
    page.wait_for_timeout(100)


def transport_click(page, logical_x):
    """Click the shared 64-pixel transport slots using the renderer's scale."""
    viewport = page.viewport_size
    scale = min(viewport["width"] / 1280, viewport["height"] / 900)
    page.mouse.move(logical_x * scale, viewport["height"] - 40 * scale)
    page.mouse.down()
    page.wait_for_timeout(100)
    page.mouse.up()
    page.wait_for_timeout(100)


def wait_tick(frame, condition, timeout):
    """Wait for observable playback progress while surfacing replay errors."""
    frame.wait_for_function(f"() => failed || ({condition})", timeout=timeout)
    assert_healthy(frame)


def malformed_chats(replay):
    """Keep a real tape's setup while forging only bounded chat metadata."""
    magic = b"POLYWORLDREPLAY"
    assert replay.startswith(magic), "Expected a native-verified Polyworld tape"
    envelope, version, game_bytes = struct.unpack_from("<HHH", replay, len(magic))
    assert envelope == 2
    position = len(magic) + 6
    assert replay[position:position + game_bytes] == b"generals"
    assert version == 4, "Expected the current compact replay version"
    # Tape versions, generator metadata, then the fixed-size public roster.
    position += game_bytes + 18
    for _ in range(10):
        name_bytes, = struct.unpack_from("<q", replay, position)
        assert 0 <= name_bytes <= 128
        position += 8 + name_bytes + 4
    # Preserve the visibility flag and five 64-bit config fields.
    position += 1 + 40
    assert position <= len(replay)
    prefix = replay[:position] + struct.pack("<qq", 0, 0)
    return {
        "chat_count": prefix + struct.pack("<q", 1_000_000) + bytes(1_000_000),
        "chat_truncated": prefix + struct.pack("<q", 1) + bytes(15),
        "chat_text": prefix + struct.pack("<qIIq", 1, 0, 0, 561) + b"x" * 561,
    }


def open_replay(browser, base, fixture, timeout, query=False, error=False):
    """Load a fresh embedded viewer and verify its loading lifecycle."""
    page = browser.new_page(viewport={"width": 1280, "height": 900})
    page.set_default_timeout(timeout)
    page.set_default_navigation_timeout(timeout)
    requests = []
    page.on("request", lambda request: requests.append(request.url))
    viewer = base + "/index.html"
    if fixture is not None:
        viewer += ("?" if query else "#") + "replay=" + quote(
            base + "/_fixture/" + fixture, safe=""
        )
    response = page.goto(base + "/_probe?viewer=" + quote(viewer, safe=""))
    assert response.headers["content-security-policy"] == CSP
    kind = "error" if error else "ready"
    page.wait_for_function(
        "() => replayMessages.some(entry => entry.type === 'error' || "
        "entry.type === 'ready')"
    )
    frame = page.frame(name="viewer")
    messages = page.evaluate("replayMessages")
    assert messages[0]["type"] == "loading", messages
    assert any(message["type"] == kind for message in messages), messages
    assert all(url.startswith(base + "/") for url in requests), requests
    if error:
        assert frame.locator("#status").is_visible()
        assert frame.locator("#status-detail").inner_text().strip()
    else:
        assert_healthy(frame)
        assert not frame.locator("#status").is_visible()
        ready = next(message for message in messages if message["type"] == kind)
        assert ready["tick"] == 0, ("Replay did not start at tick zero", ready)
        frame.locator("#canvas").focus()
    return page, frame, messages


def check_playback(browser, base, args, report):
    """Exercise autoplay, controls, determinism, looping, and iframe resizing."""
    page, frame, messages = open_replay(
        browser, base, "replay", args.timeout
    )
    try:
        wait_tick(frame, "Module.replayTick >= 5", args.timeout)
        page.screenshot(path=str(args.output / "first-frame.png"))
        # End must wrap with the default loop setting before it is toggled off.
        key(page, "End")
        wait_tick(frame, "Module.replayTick < 5", args.timeout)
        transport_click(page, 420)
        key(page, "End")
        wait_tick(frame, f"Module.replayTick === {args.end_tick}", args.timeout)
        page.wait_for_timeout(700)
        assert frame.evaluate("Module.replayTick") == args.end_tick
        assert_healthy(frame)
        page.screenshot(path=str(args.output / "last-frame.png"))
        # A paused final step must stay paused even when looping is enabled.
        key(page, "ArrowLeft")
        wait_tick(frame, f"Module.replayTick === {args.end_tick - 1}", args.timeout)
        transport_click(page, 420)
        key(page, "ArrowRight")
        wait_tick(frame, f"Module.replayTick === {args.end_tick}", args.timeout)
        page.wait_for_timeout(800)
        assert frame.evaluate("Module.replayTick") == args.end_tick, (
            "Paused final step unexpectedly restarted the replay"
        )
        transport_click(page, 420)
        # Seeking to the end resimulates and checks every recorded state hash.
        key(page, "Home")
        wait_tick(frame, "Module.replayTick < 5", args.timeout)
        key(page, "Space")
        paused = frame.evaluate("Module.replayTick")
        page.wait_for_timeout(800)
        assert frame.evaluate("Module.replayTick") == paused, "Pause failed"
        key(page, "ArrowRight")
        assert frame.evaluate("Module.replayTick") == paused + 1
        key(page, "ArrowLeft")
        assert frame.evaluate("Module.replayTick") == paused
        # The 16x button must advance substantially faster than two ticks/second.
        transport_click(page, 724)
        key(page, "Space")
        before = frame.evaluate("Module.replayTick")
        page.wait_for_timeout(1500)
        after = frame.evaluate("Module.replayTick")
        assert after - before >= min(10, args.end_tick - before), (
            "16x speed button did not accelerate playback", before, after
        )
        assert_healthy(frame)
        page.set_viewport_size({"width": 960, "height": 640})
        frame.wait_for_function(
            "() => Module.canvas.width === 960 && Module.canvas.height === 640"
        )
        page.screenshot(path=str(args.output / "resized.png"))
        # Turn looping back on and check a second wrap at the smaller viewport.
        transport_click(page, 420)
        key(page, "End")
        wait_tick(frame, f"Module.replayTick < {args.end_tick // 2}", args.timeout)
        report["playback"] = {
            "end_tick": args.end_tick,
            "messages": messages,
            "autoplay": True,
            "default_loop": True,
            "pause_and_step": True,
            "paused_loop_endpoint": True,
            "full_replay_hashes": True,
            "speed_16x": True,
            "resize": [960, 640],
        }
        print("Playback, full replay hashes, controls, loop, and resize passed",
              flush=True)
    finally:
        page.close()


def check_loads(browser, base, args, report, chat_cases):
    """Check gzip magic, legacy query URLs, and visible boundary failures."""
    cases = [
        ("gzip", "gzip", False, False),
        ("query", "replay", True, False),
        ("missing", "missing", False, True),
        ("corrupt", "corrupt", False, True),
        ("no_replay", None, False, True),
    ]
    cases.extend((name, name, False, True) for name in chat_cases)
    for name, fixture, query, error in cases:
        page, frame, messages = open_replay(
            browser, base, fixture, args.timeout, query=query, error=error
        )
        try:
            if name == "gzip":
                fetched = next(
                    message for message in messages
                    if message.get("phase") == "replay_fetch_end"
                )
                assert fetched["compressed"] is True, messages
            if not error:
                wait_tick(frame, "Module.replayTick > 0", args.timeout)
            else:
                page.screenshot(path=str(args.output / f"{name}.png"))
                if name in chat_cases:
                    expected = CHAT_ERRORS[name]
                    detail = frame.locator("#status-detail").inner_text()
                    assert expected in detail, (name, detail)
                    assert any(
                        message["type"] == "error" and
                        expected in message.get("message", "")
                        for message in messages
                    ), messages
                    assert not any(message["type"] == "ready" for message in messages)
                    assert frame.evaluate("failed && !ready")
            report[name] = messages
            print(f"{name}: {'visible error' if error else 'playback'} passed",
                  flush=True)
        finally:
            page.close()


def main():
    """Serve a supplied native replay and run browser acceptance checks."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path,
                        default=ROOT / "out/coworld/replay-viewer")
    parser.add_argument("--replay", type=Path, required=True)
    parser.add_argument("--end-tick", type=int, required=True,
                        help="Native-verified final replay tick, at least 16")
    parser.add_argument("--output", type=Path,
                        default=ROOT / "out/coworld/browser")
    parser.add_argument("--browser", type=Path,
                        default=CHROME if CHROME.is_file() else None)
    parser.add_argument("--timeout", type=int, default=120000,
                        help="Browser operation timeout in milliseconds")
    args = parser.parse_args()
    if args.end_tick < 16:
        parser.error("--end-tick must be at least 16 for playback checks")
    if not (args.bundle / "index.html").is_file():
        parser.error("--bundle must contain index.html")
    if not args.replay.is_file():
        parser.error("--replay must name a native-verified replay file")
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        parser.error("Playwright is required: python -m pip install playwright")
    args.output.mkdir(parents=True, exist_ok=True)
    replay = args.replay.read_bytes()
    if replay.startswith(b"\x1f\x8b"):
        replay = gzip.decompress(replay)
    chat_cases = malformed_chats(replay)

    def handler(*arguments, **keywords):
        """Bind static file requests to this build's bundle directory."""
        return Handler(*arguments, directory=str(args.bundle), **keywords)

    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    server.daemon_threads = True
    server.fixtures = {
        "/_probe": ("text/html; charset=utf-8", PROBE),
        "/_fixture/replay": ("application/octet-stream", replay),
        "/_fixture/gzip": ("application/octet-stream",
                           gzip.compress(replay, mtime=0)),
        "/_fixture/corrupt": ("application/octet-stream", b"invalid replay"),
    }
    server.fixtures.update({
        f"/_fixture/{name}": ("application/octet-stream", content)
        for name, content in chat_cases.items()
    })
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    report = {"bundle": str(args.bundle), "replay": str(args.replay)}
    try:
        with sync_playwright() as playwright:
            options = {
                "headless": True,
                "args": ["--enable-unsafe-swiftshader", "--use-angle=swiftshader"],
            }
            if args.browser:
                options["executable_path"] = str(args.browser)
            browser = playwright.chromium.launch(**options)
            try:
                base = f"http://127.0.0.1:{server.server_port}"
                check_playback(browser, base, args, report)
                check_loads(browser, base, args, report, chat_cases)
            finally:
                browser.close()
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
        (args.output / "browser.json").write_text(
            json.dumps(report, indent=2) + "\n", encoding="utf-8"
        )


if __name__ == "__main__":
    main()
