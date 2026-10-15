"""Four-seat scheduling, elimination boundaries, and building over the wire."""

import asyncio
import json
from collections import deque
from contextlib import ExitStack

import jax.numpy as jnp
from fastapi.testclient import TestClient

from generals.core.game import create_initial_state
from integrations.softmax.config import GameConfig
from integrations.softmax.engine import Match
from integrations.softmax.protocol import PASS
from integrations.softmax.server import Episode, create_app


def config(count=4, **extra):
    return GameConfig(tokens=[f"test-{s}" for s in range(count)],
                      players=[{"name": f"Player {s}"} for s in range(count)],
                      seed=7, max_turns=4, **extra)


def destinations(tmp_path):
    return {key: (tmp_path / f"{key}.json").as_uri() for key in ("results", "replay", "failure")}


def receive(ws, kind):
    while True:
        message = ws.receive_json()
        if message["type"] == kind:
            return message


def test_four_players_authenticate_and_finish_websocket_episode(tmp_path):
    with TestClient(create_app(config(), destinations(tmp_path))) as client, ExitStack() as stack:
        assert client.get("/client/player?slot=3&token=test-3").status_code == 200
        assert client.get("/client/player?slot=4&token=test-3").status_code == 403
        assert client.get("/client/player?slot=03&token=test-3").status_code == 403
        sockets = [stack.enter_context(client.websocket_connect(f"/player?slot={s}&token=test-{s}"))
                   for s in range(4)]
        for _ in range(4):
            observations = [receive(ws, "observation") for ws in sockets]
            assert all(len(o["public_scores"]["army"]) == 4 for o in observations)
            for ws, obs in zip(sockets, observations):
                ws.send_json({"type": "action", "turn": obs["turn"], "action": PASS})
        result = receive(sockets[0], "final")["result"]
        assert result["scores"] == [0] * 4 and result["timeouts"] == [0] * 4
        replay = client.get("/replay.json").json()
        assert len(replay["players"]) == 4 and len(replay["frames"]) == 5
        assert set(value for row in replay["frames"][0]["owner_grid"] for value in row) == {0, 1, 2, 3, 4}


def test_ffa_forfeit_eliminates_only_missing_player_and_keeps_running(tmp_path):
    async def run():
        cfg = config(max_consecutive_timeouts=1, turn_timeout_seconds=0.05)
        episode = Episode(cfg, Match(7, num_players=4), destinations(tmp_path))
        episode.players = {slot: asyncio.Queue() for slot in range(4)}

        async def player(slot):
            while True:
                message = await episode.players[slot].get()
                if message["type"] == "final":
                    return
                if message["type"] == "observation" and not message["eliminated"] and slot != 3:
                    episode.accept(slot, {"type": "action", "turn": message["turn"], "action": PASS})

        async with asyncio.timeout(10):
            await asyncio.gather(episode.run(), *(player(s) for s in range(4)))
        assert episode.result["turns"] == 4
        assert episode.result["reason"] == "turn_limit"
        assert episode.result["timeouts"] == [0, 0, 0, 1]
        assert episode.frames[-1]["eliminated"] == [False, False, False, True]
        assert episode.turns[0]["forfeited"] == [3] and episode.turns[0]["applied"]
        assert all(not turn["timed_out"][3] for turn in episode.turns[1:])
        # Replay resimulation includes forfeits before moves.
        match = Match(7, num_players=4)
        for attempt, frame in zip(episode.turns, episode.frames[1:]):
            match.forfeit(attempt["forfeited"])
            match.advance(attempt["actions"])
            assert match.frame() == frame

    asyncio.run(run())


def test_build_action_changes_replay_and_next_observation(tmp_path):
    with TestClient(create_app(config(2, ruleset="build_castles"), destinations(tmp_path))) as client:
        episode = client.app.state.episode
        grid = jnp.zeros((8, 8), dtype=jnp.int32).at[0, 0].set(1).at[7, 7].set(2)
        state = create_initial_state(grid)
        episode.match.state = state._replace(
            armies=state.armies.at[0, 1].set(50),
            ownership=state.ownership.at[0, 0, 1].set(True),
            ownership_neutral=state.ownership_neutral.at[0, 1].set(False))
        episode.match.height = episode.match.width = 8
        episode.frames = [episode.match.frame()]
        with client.websocket_connect("/player?slot=0&token=test-0") as red, \
                client.websocket_connect("/player?slot=1&token=test-1") as blue:
            for turn in range(4):
                robs, bobs = receive(red, "observation"), receive(blue, "observation")
                if turn == 0:
                    assert robs["build_cost_grid"][0][1] == 47
                elif turn == 1:
                    assert robs["last_build_executed"] is True
                    assert robs["type_grid"][0][1] == 3
                for ws, obs, action in ((red, robs, [2, 0, 1, 0, 0] if turn == 0 else PASS),
                                        (blue, bobs, PASS)):
                    ws.send_json({"type": "action", "turn": obs["turn"], "action": action})
            assert receive(red, "final")["result"]["timeouts"] == [0, 0]
        replay = json.loads((tmp_path / "replay.json").read_text())
        assert replay["ruleset"] == "build_castles"
        assert replay["frames"][1]["type_grid"][0][1] == 3


def test_classic_players_trade_generals_and_finish_with_replay(tmp_path):
    """Two real players walk across a generated map and exchange generals together."""
    cfg = GameConfig(
        tokens=["trade-0", "trade-1"], players=[{"name": "Red"}, {"name": "Blue"}],
        seed=7, max_turns=600, turn_timeout_seconds=1,
    )
    with TestClient(create_app(cfg, destinations(tmp_path))) as client, ExitStack() as stack:
        sockets = [stack.enter_context(client.websocket_connect(f"/player?slot={s}&token=trade-{s}"))
                   for s in range(2)]
        generals = []
        positions = []
        previous = [PASS.copy(), PASS.copy()]
        # Opposite flanks keep the two scripted armies from fighting before the trade.
        flanked = [False, False]
        blocked = [set(), set()]
        traded_turn = None
        directions = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        for turn in range(600):
            observations = [receive(ws, "observation") for ws in sockets]
            if turn == 0:
                generals = [next((r, c) for r, row in enumerate(o["type_grid"]) for c, kind in enumerate(row)
                                 if kind == 4 and o["owner_grid"][r][c] == 1) for o in observations]
                positions = generals.copy()
            actions = [PASS.copy(), PASS.copy()]
            ready = [False, False]
            for slot, obs in enumerate(observations):
                assert not obs["eliminated"]
                if traded_turn is not None:
                    if turn == traded_turn + 1:
                        assert obs["last_move_executed"] is True
                        r, c = generals[1 - slot]
                        assert obs["type_grid"][r][c] == 4 and obs["owner_grid"][r][c] == 1
                    continue
                if previous[slot][0] == 0 and obs["last_move_executed"]:
                    dr, dc = directions[previous[slot][3]]
                    destination = (previous[slot][1] + dr, previous[slot][2] + dc)
                    if obs["owner_grid"][destination[0]][destination[1]] == 1:
                        positions[slot] = destination
                if turn < 300:
                    continue
                for r, row in enumerate(obs["type_grid"]):
                    for c, kind in enumerate(row):
                        if kind in (2, 5):
                            blocked[slot].add((r, c))
                source = positions[slot]
                target = generals[1 - slot]
                flank_column = 0 if slot == 0 else obs["width"] - 1
                if source[1] == flank_column:
                    flanked[slot] = True
                queue = deque([(source, [])])
                visited = {source}
                route = None
                while queue:
                    cell, path = queue.popleft()
                    if (cell == target if flanked[slot] else cell[1] == flank_column):
                        route = path
                        break
                    for direction, (dr, dc) in enumerate(directions):
                        nxt = (cell[0] + dr, cell[1] + dc)
                        if (0 <= nxt[0] < obs["height"] and 0 <= nxt[1] < obs["width"]
                                and nxt not in blocked[slot] and nxt not in visited):
                            visited.add(nxt)
                            queue.append((nxt, path + [direction]))
                assert route, "generated map must allow a route between generals"
                ready[slot] = flanked[slot] and len(route) == 1
                actions[slot] = [0, source[0], source[1], route[0], 0]
            if all(ready):
                traded_turn = turn
            else:
                for slot in range(2):
                    if ready[slot]:
                        actions[slot] = PASS.copy()
            previous = actions
            for ws, action in zip(sockets, actions):
                ws.send_json({"type": "action", "turn": turn, "action": action})
        result = receive(sockets[0], "final")["result"]
        assert traded_turn is not None and traded_turn < 599, (generals, positions)
        assert result["scores"] == [0, 0] and result["timeouts"] == [0, 0]
        replay = client.get("/replay.json").json()
        assert replay["result"] == result
        frame = replay["frames"][traded_turn + 1]
        assert frame["eliminated"] == [False, False]
        for slot in range(2):
            r, c = generals[1 - slot]
            assert frame["type_grid"][r][c] == 4 and frame["owner_grid"][r][c] == slot + 1
        assert json.loads((tmp_path / "results.json").read_text()) == result
