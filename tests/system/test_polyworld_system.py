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
        replay = client.get("/client/replay.json").json()
    assert len({slot for _, slot, _, _ in built}) == 2
    assert replay == json.loads((tmp_path / "replay.json").read_text())
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
        replay = client.get("/client/replay.json").json()
    assert result["winner"] == 2 and result["turns"] == 1
    assert result == json.loads((tmp_path / "results.json").read_text())
    assert [replay_frame(replay["frames"], i)["turn"] for i in range(2)] == [0, 1]
