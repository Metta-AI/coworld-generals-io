"""Check the hosted game through CoWorld's local file and probe contracts."""

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid
import zipfile


ROOT = Path(__file__).resolve().parents[1]
LOG_LIMIT = 10 * 1024 * 1024


def package(source, compression=zipfile.ZIP_DEFLATED, extra=None):
    """Wrap a BASIC policy in the supported staged ZIP format."""
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=compression) as archive:
        archive.writestr("policy.bas", source)
        for name, content in (extra or {}).items():
            archive.writestr(name, content)
    return output.getvalue()


def read_bytes(connection, count):
    """Read an exact, bounded network field with the socket timeout."""
    output = bytearray()
    while len(output) < count:
        part = connection.recv(count - len(output))
        assert part, "Probe socket closed early"
        output.extend(part)
    return bytes(output)


def read_frame(connection):
    """Read one short unmasked server frame used by the legacy probe."""
    header = read_bytes(connection, 2)
    assert header[0] & 0x80 and not header[0] & 0x70
    assert not header[1] & 0x80 and header[1] < 126
    return header[0] & 15, read_bytes(connection, header[1])


def check_probes(port):
    """Check HTTP stubs and the status plus exact WebSocket Ping/Pong."""
    base = f"http://127.0.0.1:{port}"
    for path in ("/healthz", "/client/global", "/client/player", "/client/replay"):
        with urllib.request.urlopen(base + path, timeout=5) as response:
            assert response.status == 200, path
            body = response.read()
            if path == "/healthz":
                assert body == b"ok"
    try:
        urllib.request.urlopen(base + "/not-implemented", timeout=5)
    except urllib.error.HTTPError as error:
        assert error.code == 501
    else:
        raise AssertionError("Unimplemented route should return HTTP 501")
    with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
        connection.sendall((
            "GET /global HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{port}\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        ).encode())
        headers = bytearray()
        while not headers.endswith(b"\r\n\r\n"):
            assert len(headers) < 16384
            headers.extend(read_bytes(connection, 1))
        assert bytes(headers).split(b"\r\n", 1)[0].split()[1] == b"101"
        assert b"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" in headers
        opcode, status = read_frame(connection)
        assert opcode == 1 and json.loads(status)["type"] == "status"
        payload, mask = b"generals-coworld-probe", b"test"
        connection.sendall(bytes([0x89, 0x80 | len(payload)]) + mask + bytes(
            value ^ mask[index % 4] for index, value in enumerate(payload)
        ))
        assert read_frame(connection) == (10, payload)


def fixture(slot, scout, annotations=True):
    """Add private output, metadata queries, and an optional annotation."""
    source = (
        f'PRINT "PRIVATE-SEAT-{slot}", 1.5\n'
        'PRINT playerName$(selfPlayer())\n'
        'PRINT playerMmr(selfPlayer())\n'
    )
    if annotations:
        source += (
            'status = ANNOTATE(123, "intent", "selectTarget", '
            f'"{{""target"":{slot}}}")\n'
        )
    return source.encode() + scout


def episode(args, root, name, sources, ticks=24, failed_slot=None,
            runtime_error=False, annotations=True, expose=True):
    """Stage one episode and inspect outputs before allowing collection."""
    directory = root / name
    directory.mkdir()
    count = len(sources)
    config = {
        "tokens": [f"secret-token-{slot}" for slot in range(count)],
        "players": [
            {"name": f"Hosted Player {slot}", "mmr": 31 + slot}
            for slot in range(count)
        ],
        "seed": 2026,
        "max_ticks": ticks,
        "expose_player_info": expose,
    }
    seats = []
    for slot, source in enumerate(sources):
        path = directory / f"player-{slot}"
        path.write_bytes(source)
        seat = {
            "slot": slot,
            "file_uri": path.as_uri(),
            "content_hash": "sha256:" + hashlib.sha256(source).hexdigest(),
            "size_bytes": len(source),
            "log_uri": (directory / f"player-{slot}.log").as_uri(),
            "artifact_uri": (directory / f"player-{slot}.zip").as_uri(),
        }
        if annotations:
            seat["annotations_uri"] = (directory / f"player-{slot}.jsonl").as_uri()
        seats.append(seat)
    documents = {
        "CONFIG": config,
        "PLAYER_SEATS": {
            "schema": f"coworld-player-seats/{2 if annotations else 1}",
            "seats": seats,
            "player_status_uri": (directory / "status.json").as_uri(),
        },
    }
    env = os.environ.copy()
    for key, value in documents.items():
        path = directory / f"{key}.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        env[f"COGAME_{key}_URI"] = path.as_uri()
    for key, filename in {
        "RESULTS": "results.json", "SAVE_REPLAY": "replay",
        "PLAYER_FAILURE": "failure.json",
    }.items():
        env[f"COGAME_{key}_URI"] = (directory / filename).as_uri()
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    env.update(COGAME_HOST="127.0.0.1", COGAME_PORT=str(port))
    command = [str(args.executable)]
    container = None
    if args.docker_image:
        container = "generals-check-" + uuid.uuid4().hex
        env.update(COGAME_HOST="0.0.0.0", COGAME_PORT="8080")
        command = [
            "docker", "run", "--rm", "--init", "--platform", "linux/amd64",
            "--name", container, "--publish", f"127.0.0.1:{port}:8080",
            "--volume", f"{directory}:{directory}",
        ]
        for key, value in env.items():
            if key.startswith("COGAME_"):
                command += ["--env", f"{key}={value}"]
        command.append(args.docker_image)
    rejected = failed_slot is not None and not runtime_error
    marker = directory / ("failure.json" if rejected else "results.json")
    unexpected = directory / ("results.json" if rejected else "failure.json")
    game_log = directory / "game.log"
    started = time.monotonic()
    with game_log.open("xb") as output:
        process = subprocess.Popen(
            command, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT
        )
        try:
            while not marker.exists():
                assert not unexpected.exists(), unexpected.read_text()
                assert process.poll() is None, game_log.read_text()
                assert time.monotonic() - started < args.timeout, (
                    f"{name}: no completion marker\n{game_log.read_text()}"
                )
                time.sleep(0.02)
            outcome = json.loads(marker.read_text())
            assert not unexpected.exists(), name
            assert not list(directory.glob("*.tmp")), "Unfinished atomic output"
            statuses = json.loads((directory / "status.json").read_text())["players"]
            assert [status["slot"] for status in statuses] == list(range(count))
            logs = [
                (directory / f"player-{slot}.log").read_text()
                for slot in range(count)
            ]
            public = game_log.read_text()
            assert "PRIVATE-SEAT-" not in public
            assert "BASIC error:" not in public
            for slot, (log, status) in enumerate(zip(logs, statuses)):
                assert status["state"] == "exited"
                assert status["exit_code"] == int(slot == failed_slot)
                assert len(log.encode()) <= LOG_LIMIT
                assert not (directory / f"player-{slot}.zip").exists()
                for other in range(count):
                    if other != slot:
                        assert f"PRIVATE-SEAT-{other}" not in log
            if rejected:
                assert outcome == {
                    "message": f"Policy loading failed for player slot {failed_slot}",
                    "failed_policy_index": failed_slot,
                }
                assert "BASIC error:" in logs[failed_slot]
                assert not (directory / "replay").exists()
                replay = b""
            else:
                assert len(outcome["scores"]) == count
                assert all(type(score) is int and score in (0, 1)
                           for score in outcome["scores"])
                assert sum(outcome["scores"]) in (0, 1)
                assert outcome["seed"] == 2026
                assert 0 < outcome["ticks"] <= ticks
                assert outcome["outcome"] in ("draw", "victory")
                assert (outcome["outcome"] == "victory") == (
                    sum(outcome["scores"]) == 1
                )
                replay = (directory / "replay").read_bytes()
                assert replay, "Completion preceded replay"
                decoded = (
                    gzip.decompress(replay) if replay[:2] == b"\x1f\x8b" else replay
                )
                assert b"PRIVATE-SEAT-" not in decoded
                assert b"secret-token-" not in decoded
                assert str(directory).encode() not in decoded
                for slot, log in enumerate(logs):
                    assert f"Hosted Player {slot}".encode() in decoded
                    if sources[slot].startswith(b'PRINT "PRIVATE-SEAT-'):
                        assert f"PRIVATE-SEAT-{slot} 1.50000" in log
                        if expose:
                            assert f"Hosted Player {slot}\n{31 + slot}\n" in log
                        else:
                            assert f"Hosted Player {slot}" not in log
                    annotation = directory / f"player-{slot}.jsonl"
                    if annotation.exists():
                        assert annotations
                        events = [
                            json.loads(line)
                            for line in annotation.read_text().splitlines()
                        ]
                        assert events
                        for event in events:
                            assert event == {
                                "schema_version": 1, "time": 123, "kind": "intent",
                                "function": "selectTarget", "args": {"target": slot},
                            }
                        assert "selectTarget" not in log
                    elif annotations and b"ANNOTATE" in sources[slot]:
                        raise AssertionError(f"Missing annotation for seat {slot}")
                if runtime_error:
                    assert "BASIC error:" in logs[failed_slot]
                    assert "instruction limit" in logs[failed_slot]
            check_probes(port)
            assert process.poll() is None, "Host stopped before output collection"
        finally:
            if container:
                subprocess.run(
                    ["docker", "stop", "--time", "2", container],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    timeout=15, check=False,
                )
            elif process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    if not rejected:
        assert process.returncode == 0, f"{name}: unclean completed shutdown"
    print(f"PASS {name} ({time.monotonic() - started:.2f}s)", flush=True)
    return outcome, replay


def main():
    """Verify native or containerized hosted games without platform access."""
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group()
    target.add_argument(
        "--executable", type=Path, default=ROOT / "out/generals-coworld"
    )
    target.add_argument("--docker-image")
    parser.add_argument(
        "--evidence", type=Path,
        help="Retain episode artifacts below this directory",
    )
    parser.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args()
    args.executable = args.executable.resolve()
    assert args.docker_image or args.executable.is_file(), (
        "Build the hosted executable first"
    )
    if args.evidence:
        args.evidence = args.evidence.resolve()
        args.evidence.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="generals-coworld-") as temporary:
        root = (
            Path(tempfile.mkdtemp(prefix="run-", dir=args.evidence))
            if args.evidence else Path(temporary)
        )
        scout = (ROOT / "examples/scout.bas").read_bytes()
        pair = [fixture(slot, scout) for slot in range(2)]
        first = episode(args, root, "two-raw", pair)
        second = episode(args, root, "two-repeat", pair)
        assert first == second, "Same seed and actions changed results or replay bytes"
        print("PASS deterministic results and byte-identical replay", flush=True)
        ten = []
        for slot in range(10):
            source = fixture(slot, scout)
            ten.append(source if slot % 3 == 0 else package(
                source, zipfile.ZIP_STORED if slot % 3 == 1 else zipfile.ZIP_DEFLATED,
                {"resource.bin": b"test resource"},
            ))
        episode(args, root, "ten-mixed-packages", ten, ticks=60)
        episode(args, root, "metadata-disabled", pair, annotations=False, expose=False)
        episode(args, root, "empty-policies", [b"", b""])
        episode(args, root, "compile-failure", [
            b'PRINT "unterminated\n', pair[1],
        ], failed_slot=0)
        episode(args, root, "package-traversal", [
            pair[0], package(pair[1], extra={"../outside": b"forbidden"}),
        ], failed_slot=1)
        episode(args, root, "runtime-failure", [
            b"WHILE 1\nvalue = 1\nWEND\n", pair[1],
        ], failed_slot=0, runtime_error=True)
        if args.evidence:
            print(f"Evidence: {root}")
    print("PASS CoWorld hosted runtime contract")


main()
