"""Real engine, BASIC processes, socket players, and persisted episode outputs.

Build basic_worker.nim and set GENERALS_BASIC_WORKER to run these system checks.
"""

import json
import os
from contextlib import ExitStack
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from integrations.softmax.config import GameConfig
from integrations.softmax.server import create_app


@pytest.mark.parametrize("engine", ["jax", "polyworld"])
def test_basic_container_and_human_seats_complete_one_game(tmp_path: Path, monkeypatch, engine):
    if "GENERALS_BASIC_WORKER" not in os.environ:
        pytest.skip("Build the native BASIC worker and set GENERALS_BASIC_WORKER")
    source = Path("integrations/softmax/players/baseline.bas").read_text()
    (tmp_path / "policy").write_text('print "PRIVATE", slot, turn\nprint "SKILL", playerSkill(1), playerRated(1), playerRated(3), playerSkill(3)\n' + source)
    seats = []
    for slot in range(4):
        if slot in (1, 2):
            seats.append({"slot": slot, "kind": "human" if slot == 1 else "container"})
        else:
            seats.append(
                {
                    "slot": slot,
                    "kind": "policy",
                    "file_uri": (tmp_path / "policy").as_uri(),
                    "content_hash": "sha256:" + "a" * 64,
                    "size_bytes": (tmp_path / "policy").stat().st_size,
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
                ws.send_json({"type": "action", "turn": turn, "action": [1, 0, 0, 0, 0]})
        for ws in sockets:
            assert ws.receive_json()["type"] == "final"
        assert client.get("/client/replay.json").status_code == 200
    result = json.loads((tmp_path / "results.json").read_text())
    assert result["turns"] == 40 and result["timeouts"] == [0] * 4
    replay = json.loads((tmp_path / "replay.json").read_text())
    assert replay["engine"] == engine
    assert any(turn["actions"][0][0] == 0 for turn in replay["turns"])
    for slot in (0, 3):
        log = (tmp_path / f"seat-{slot}.log").read_text()
        assert "SKILL -234 1 0 0" in log
        assert f"PRIVATE {slot} 39" in log
        assert f"PRIVATE {3 - slot} " not in log
    assert not (tmp_path / "failure.json").exists()


@pytest.mark.parametrize("source", ["this is not BASIC", "do\nloop"])
@pytest.mark.parametrize("engine", ["jax", "polyworld"])
def test_broken_basic_never_publishes_competitive_scores(tmp_path: Path, monkeypatch, source, engine):
    if "GENERALS_BASIC_WORKER" not in os.environ:
        pytest.skip("Build the native BASIC worker and set GENERALS_BASIC_WORKER")
    (tmp_path / "policy").write_text(source)
    seats = [
        {
            "kind": "policy",
            "slot": s,
            "file_uri": (tmp_path / "policy").as_uri(),
            "content_hash": "sha256:" + "b" * 64,
            "size_bytes": len(source),
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
