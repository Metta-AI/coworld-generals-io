"""Real engine, BASIC processes, socket players, and persisted episode outputs.

Build basic_worker.nim and set GENERALS_BASIC_WORKER to run these system checks.
"""

import json
import os
from contextlib import ExitStack
from pathlib import Path
from zipfile import ZipFile

import pytest
from fastapi.testclient import TestClient

from integrations.softmax.config import GameConfig
from integrations.softmax.server import create_app


@pytest.mark.parametrize("engine", ["jax", "polyworld"])
def test_basic_container_and_human_seats_complete_one_game(tmp_path: Path, monkeypatch, engine, inspect_native_replay):
    if "GENERALS_BASIC_WORKER" not in os.environ:
        pytest.skip("Build the native BASIC worker and set GENERALS_BASIC_WORKER")
    source = Path("integrations/softmax/players/baseline.bas").read_text()
    (tmp_path / "policy").write_text("""
print "PRIVATE", slot, turn
print "SKILL", playerSkill(1), playerRated(1), playerRated(3), playerSkill(3)
print "NAME "; playerName$(2); " / "; mailboxName$(1)
print "FLAT", selfPlayer(), playerCount(), width(), height(), tileCount()
print "HOME", owner(selfGeneral()), visible(selfGeneral()), terrain(selfGeneral())
if worldTick() = 0 then
  if selfPlayer() = 0 then accepted = sendChat(2, "BASIC_PRIVATE")
  if selfPlayer() = 3 then accepted = sendChat(-2, "ZIP_PUBLIC")
  rejected = sendChat(-2, "MUST_NOT_DELIVER")
  print "CHAT", accepted, rejected
end if
while mailboxCount() > 0
  message$ = pullMailbox$()
  print "MAIL", mailboxId(); " "; message$
wend
""" + source)
    with ZipFile(tmp_path / "package", "w") as package:
        package.writestr("main.bas", (tmp_path / "policy").read_bytes())
    seats = []
    for slot in range(4):
        if slot in (1, 2):
            seats.append({"slot": slot, "kind": "human" if slot == 1 else "container"})
        else:
            seats.append(
                {
                    "slot": slot,
                    "kind": "policy",
                    "file_uri": (tmp_path / ("policy" if slot == 0 else "package")).as_uri(),
                    "content_hash": "sha256:" + "a" * 64,
                    "size_bytes": (tmp_path / ("policy" if slot == 0 else "package")).stat().st_size,
                    "log_uri": (tmp_path / f"seat-{slot}.log").as_uri(),
                    "artifact_uri": (tmp_path / f"seat-{slot}.zip").as_uri(),
                }
            )
    roster = tmp_path / "seats.json"
    roster.write_text(
        json.dumps(
            {"schema": "coworld-play-seats/2", "seats": seats, "player_status_uri": (tmp_path / "status.json").as_uri()}
        )
    )
    monkeypatch.setenv("COGAME_PLAYER_SEATS_URI", roster.as_uri())
    config = GameConfig(
        tokens=[f"token-{s}" for s in range(4)],
        players=[{"name": f"Player {s}"} for s in range(4)],
        player_ratings={"league": "Fixture FFA", "label": "MMR", "players": [
            {"slot": 0, "score": 27.38}, {"slot": 1, "score": -2.34},
            {"slot": 2, "score": 0.0}, {"slot": 3, "score": None},
        ]},
        seed=7,
        max_turns=40,
    )
    artifacts = {name: (tmp_path / f"{name}.json").as_uri() for name in ("results", "replay", "failure")}
    with TestClient(create_app(config, artifacts, engine=engine)) as client, ExitStack() as stack:
        sockets = [stack.enter_context(client.websocket_connect(f"/player?slot={s}&token=token-{s}")) for s in (1, 2)]
        for ws in sockets:
            assert ws.receive_json()["type"] == "hello"
        for turn in range(40):
            for ws in sockets:
                observation = ws.receive_json()
                assert observation["type"] == "observation"
                assert observation["turn"] == turn
                assert observation["player_ratings"] == config.player_ratings.model_dump(mode="json")
                assert "BASIC_PRIVATE" not in json.dumps(observation["chats"])
                assert "SOCKET_PRIVATE" not in json.dumps(observation["chats"])
                if turn == 0:
                    assert observation["mailbox"]["messages"] == []
                    ws.send_json({"type": "chat", "target": -2 if observation["slot"] == 1 else 0,
                                  "text": "SOCKET_PUBLIC" if observation["slot"] == 1 else "SOCKET_PRIVATE"})
                if turn == 1:
                    inbox = observation["mailbox"]["messages"]
                    assert [entry["id"] for entry in inbox] == ([-2, -2] if observation["slot"] == 1 else [0, -2, -2])
                    assert any("BASIC_PRIVATE" in entry["text"] for entry in inbox) == (observation["slot"] == 2)
                    ws.send_json({"type": "mailbox", "count": len(inbox)})
                if turn == 2:
                    assert observation["mailbox"]["messages"] == []
                ws.send_json({"type": "action", "turn": turn, "action": [1, 0, 0, 0, 0]})
        for ws in sockets:
            assert ws.receive_json()["type"] == "final"
        assert client.get("/client/replay.data").status_code == 200
        replay = client.get("/replay.json").json()
    result = json.loads((tmp_path / "results.json").read_text())
    assert result["turns"] == 40 and result["timeouts"] == [0] * 4
    if engine == "polyworld":
        tape = inspect_native_replay(tmp_path / "replay.json")
        assert tape["turns"] == 40
        assert [chat["text"] for chat in tape["chats"]] == ["SOCKET_PUBLIC", "ZIP_PUBLIC"]
        assert b"BASIC_PRIVATE" not in (tmp_path / "replay.json").read_bytes()
        assert b"SOCKET_PRIVATE" not in (tmp_path / "replay.json").read_bytes()
    else:
        assert json.loads((tmp_path / "replay.json").read_text())["engine"] == engine
    assert any(turn["actions"][0][0] == 0 for turn in replay["turns"])
    for slot in (0, 3):
        log = (tmp_path / f"seat-{slot}.log").read_text()
        assert "SKILL -234 1 0 0" in log
        assert f"PRIVATE {slot} 39" in log
        assert "NAME Player 2 / Player 1" in log
        assert "HOME " + str(slot) + " 1 3" in log
        assert f"CHAT {1 if slot == 0 else 4} 0" in log
        assert "MUST_NOT_DELIVER" not in log
        assert ("SOCKET_PRIVATE" in log) == (slot == 0)
        assert "BASIC_PRIVATE" not in log
        assert f"PRIVATE {3 - slot} " not in log
    assert not (tmp_path / "failure.json").exists()


def test_basic_build_reserves_the_action_like_a_socket_build(tmp_path: Path, monkeypatch, inspect_native_replay):
    """An impossible build must not let BASIC submit a second action instead."""
    if "GENERALS_BASIC_WORKER" not in os.environ:
        pytest.skip("Build the native BASIC worker and set GENERALS_BASIC_WORKER")
    policy = tmp_path / "policy"
    policy.write_text('print "BUILD", buildCastle(0, 0), move(0, 0, 3, 0)\n')
    roster = tmp_path / "seats.json"
    roster.write_text(json.dumps({
        "schema": "coworld-play-seats/2",
        "player_status_uri": (tmp_path / "status.json").as_uri(),
        "seats": [{
            "kind": "policy", "slot": 0, "file_uri": policy.as_uri(),
            "content_hash": "sha256:" + "d" * 64, "size_bytes": policy.stat().st_size,
            "log_uri": (tmp_path / "basic.log").as_uri(),
            "artifact_uri": (tmp_path / "basic.zip").as_uri(),
        }, {"kind": "container", "slot": 1}],
    }))
    monkeypatch.setenv("COGAME_PLAYER_SEATS_URI", roster.as_uri())
    config = GameConfig(tokens=["basic", "socket"], players=[{"name": "Basic"}, {"name": "Socket"}],
                        ruleset="build_castles", seed=7, max_turns=2)
    artifacts = {name: (tmp_path / name).as_uri() for name in ("results", "replay", "failure")}
    with TestClient(create_app(config, artifacts, engine="polyworld")) as client:
        with client.websocket_connect("/player?slot=1&token=socket") as opponent:
            assert opponent.receive_json()["type"] == "hello"
            for tick in range(2):
                observation = opponent.receive_json()
                assert observation["turn"] == tick
                if tick:
                    assert observation["last_build_executed"] is False
                opponent.send_json({"type": "action", "turn": tick, "action": [2, 0, 0, 0, 0]})
            final = opponent.receive_json()
            assert final["type"] == "final" and final["result"]["timeouts"] == [0, 0]
        replay = client.get("/replay.json").json()
    assert (tmp_path / "basic.log").read_text() == "BUILD 1 0\nBUILD 1 0\n"
    assert all(turn["actions"] == [[2, 0, 0, 0, 0]] * 2 for turn in replay["turns"])
    assert inspect_native_replay(tmp_path / "replay")["turns"] == 2
    assert not (tmp_path / "failure").exists()


def test_unmodified_polyworld_scout_plays_a_hosted_socket_opponent(tmp_path: Path, monkeypatch, inspect_native_replay):
    """A standalone policy must compile, communicate and move without porting."""
    if "GENERALS_BASIC_WORKER" not in os.environ:
        pytest.skip("Build the native BASIC worker and set GENERALS_BASIC_WORKER")
    policy = tmp_path / "policy"
    policy.write_bytes(Path("polyworld/examples/scout.bas").read_bytes())
    roster = tmp_path / "seats.json"
    roster.write_text(json.dumps({
        "schema": "coworld-play-seats/2",
        "player_status_uri": (tmp_path / "status.json").as_uri(),
        "seats": [{
            "kind": "policy", "slot": 0, "file_uri": policy.as_uri(),
            "content_hash": "sha256:" + "c" * 64, "size_bytes": policy.stat().st_size,
            "log_uri": (tmp_path / "scout.log").as_uri(),
            "artifact_uri": (tmp_path / "scout.zip").as_uri(),
        }, {"kind": "container", "slot": 1}],
    }))
    monkeypatch.setenv("COGAME_PLAYER_SEATS_URI", roster.as_uri())
    config = GameConfig(tokens=["scout", "socket"], players=[{"name": "Scout"}, {"name": "Socket"}],
                        seed=7, max_turns=40)
    artifacts = {name: (tmp_path / name).as_uri() for name in ("results", "replay", "failure")}
    with TestClient(create_app(config, artifacts, engine="polyworld")) as client:
        with client.websocket_connect("/player?slot=1&token=socket") as opponent:
            assert opponent.receive_json()["type"] == "hello"
            for tick in range(40):
                observation = opponent.receive_json()
                assert observation["turn"] == tick
                if tick == 1:
                    assert observation["mailbox"]["messages"] == [
                        {"id": -2, "text": "Scout: Ready to explore."},
                    ]
                opponent.send_json({"type": "action", "turn": tick, "action": [1, 0, 0, 0, 0]})
            final = opponent.receive_json()
            assert final["type"] == "final"
            assert final["result"]["timeouts"] == [0, 0]
            assert final["result"]["land"][0] > 1
            assert any(entry["id"] == -2 and "[Game]" in entry["text"]
                       for entry in final["mailbox"]["messages"])
    tape = inspect_native_replay(tmp_path / "replay")
    assert tape["turns"] == 40 and tape["actions"] > 0
    assert [chat["text"] for chat in tape["chats"]] == ["Ready to explore."]
    assert not (tmp_path / "failure").exists()


@pytest.mark.parametrize("source", ["this is not BASIC", "do\nloop", "zip_escape"])
@pytest.mark.parametrize("engine", ["jax", "polyworld"])
def test_broken_basic_never_publishes_competitive_scores(tmp_path: Path, monkeypatch, source, engine):
    if "GENERALS_BASIC_WORKER" not in os.environ:
        pytest.skip("Build the native BASIC worker and set GENERALS_BASIC_WORKER")
    if source == "zip_escape":
        with ZipFile(tmp_path / "policy", "w") as package:
            package.writestr("../main.bas", "pass()")
    else:
        (tmp_path / "policy").write_text(source)
    seats = [
        {
            "kind": "policy",
            "slot": s,
            "file_uri": (tmp_path / "policy").as_uri(),
            "content_hash": "sha256:" + "b" * 64,
            "size_bytes": (tmp_path / "policy").stat().st_size,
            "log_uri": (tmp_path / f"seat-{s}.log").as_uri(),
            "artifact_uri": (tmp_path / f"seat-{s}.zip").as_uri(),
        }
        for s in range(2)
    ]
    roster = tmp_path / "seats.json"
    roster.write_text(
        json.dumps(
            {"schema": "coworld-play-seats/2", "seats": seats, "player_status_uri": (tmp_path / "status.json").as_uri()}
        )
    )
    monkeypatch.setenv("COGAME_PLAYER_SEATS_URI", roster.as_uri())
    config = GameConfig(tokens=["red", "blue"], players=[{"name": "Red"}, {"name": "Blue"}], seed=7, max_turns=2)
    artifacts = {name: (tmp_path / f"{name}.json").as_uri() for name in ("results", "replay", "failure")}
    with TestClient(create_app(config, artifacts, engine=engine)) as client:
        with client.websocket_connect("/global") as viewer:
            message = viewer.receive_json()
            while message["phase"] != "failed":
                message = viewer.receive_json()
    failure = json.loads((tmp_path / "failure.json").read_text())
    assert failure["failed_policy_index"] == 0 and failure["kind"] == "player_error"
    assert not (tmp_path / "results.json").exists()
    assert (tmp_path / "seat-0.log").stat().st_size > 0
