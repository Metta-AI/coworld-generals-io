#!/usr/bin/env python3
"""Compare Nim with pinned, unchanged Python/JAX classic game code each tick."""

import argparse
import hashlib
import importlib.metadata
import importlib.util
import json
import os
from pathlib import Path
import random
import subprocess
import sys
import types

os.environ.setdefault("JAX_PLATFORMS", "cpu")
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
REFERENCE = ROOT / "tests" / "reference"
PASS = [1, 0, 0, 0, 0]
DIRECTIONS = [(-1, 0), (1, 0), (0, -1), (0, 1)]
SIZE = 13
PLAYER_COUNTS = tuple(range(2, 11))


def load_module(name, path):
    """Load one original source file without running its package initializer."""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def load_reference():
    """Verify source pins, then import the real engine and baseline agent."""
    manifest = json.loads((REFERENCE / "manifest.json").read_text())
    for relative, entry in manifest["files"].items():
        digest = hashlib.sha256((REFERENCE / relative).read_bytes()).hexdigest()
        if digest != entry["sha256"]:
            raise RuntimeError(f"Reference source hash changed: {relative}")
    versions = {}
    for line in (ROOT / "tools" / "reference_requirements.txt").read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        package, expected = line.split("==")
        actual = importlib.metadata.version(package)
        if actual != expected:
            raise RuntimeError(f"Install pinned dependencies: {package} {actual} != {expected}")
        versions[package] = actual
    for name in ("generals", "generals.core"):
        package = types.ModuleType(name)
        package.__path__ = [str(REFERENCE / "upstream")]
        sys.modules[name] = package
    load_module("generals.core.observation", REFERENCE / "upstream" / "observation.py")
    game = load_module("generals.core.game", REFERENCE / "upstream" / "game.py")
    agent = load_module("reference_expander", REFERENCE / "upstream" / "agent.py")
    print(f"Reference {manifest['revision']}; dependencies {versions}", flush=True)
    return game, agent.Agent


class Driver:
    """Keep the Nim engine alive across independent reset-and-step scenarios."""

    def __init__(self, path):
        self.process = subprocess.Popen(
            [str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, encoding="utf-8", cwd=ROOT,
        )

    def request(self, message):
        self.process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            error = self.process.stderr.read()
            raise RuntimeError(f"Nim reference runner stopped: {error}")
        result = json.loads(line)
        if "error" in result:
            raise RuntimeError(f"Nim reference runner rejected input: {result['error']}")
        return result

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.process.stdout.close()
        self.process.stderr.close()


def first_difference(expected, actual, path="state"):
    """Describe the first mismatched scalar without printing entire boards."""
    if type(expected) is not type(actual):
        return f"{path}: type {type(expected).__name__} != {type(actual).__name__}"
    if isinstance(expected, dict):
        if expected.keys() != actual.keys():
            return f"{path}: keys {sorted(expected)} != {sorted(actual)}"
        for key in expected:
            difference = first_difference(expected[key], actual[key], f"{path}.{key}")
            if difference:
                return difference
    elif isinstance(expected, list):
        if len(expected) != len(actual):
            return f"{path}: length {len(expected)} != {len(actual)}"
        for index, (left, right) in enumerate(zip(expected, actual)):
            difference = first_difference(left, right, f"{path}[{index}]")
            if difference:
                return difference
    elif expected != actual:
        return f"{path}: Python {expected!r} != Nim {actual!r}"
    return None


class Comparison:
    """Adapt shared data and compare outputs; all game rules stay upstream."""

    def __init__(self, game, driver, failure):
        import jax.numpy as jnp
        import numpy as np
        self.game, self.driver, self.failure = game, driver, failure
        self.jnp, self.np = jnp, np
        self.cases = self.steps = self.baseline_steps = self.action_checks = 0
        self.states = self.cells = self.observation_cells = 0
        self.native_steps = self.native_conquests = self.frozen_ticks = 0
        self.games = []

    def begin(self, name, initial):
        self.name, self.initial, self.history = name, initial, []
        self.config = initial["config"]
        self.width, self.height = self.config["width"], self.config["height"]
        self.players = self.config["players"]
        self.finished = initial["finished"]
        np, jnp = self.np, self.jnp
        shape = (self.height, self.width)
        owners = np.array([tile["owner"] for tile in initial["tiles"]]).reshape(shape)
        kinds = np.array([tile["kind"] for tile in initial["tiles"]]).reshape(shape)
        armies = np.array([tile["army"] for tile in initial["tiles"]]).reshape(shape)
        self.state = self.game.GameState(
            armies=jnp.asarray(armies, dtype=jnp.int32),
            ownership=jnp.asarray(np.arange(self.players)[:, None, None] == owners),
            ownership_neutral=jnp.asarray((owners == -1) & (kinds != 1)),
            generals=jnp.asarray(kinds == 3), castles=jnp.asarray(kinds == 2),
            mountains=jnp.asarray(kinds == 1), passable=jnp.asarray(kinds != 1),
            general_positions=jnp.asarray([
                divmod(index, self.width) for index in initial["generals"]
            ], dtype=jnp.int32),
            teams=jnp.arange(self.players, dtype=jnp.int32),
            eliminated=jnp.asarray([not alive for alive in initial["alive"]]),
            time=jnp.int32(initial["turn"]), winner=jnp.int32(initial["winner"]),
            pool_idx=jnp.int32(0),
        )
        self.actual = self.driver.request({"op": "init", **initial})
        self.compare()
        self.cases += 1

    def normalized(self):
        np, state = self.np, self.state
        owns = np.asarray(state.ownership)
        owners = np.where(owns.any(axis=0), owns.argmax(axis=0), -1)
        kinds = np.zeros_like(owners)
        for mask, kind in ((state.mountains, 1), (state.castles, 2), (state.generals, 3)):
            kinds[np.asarray(mask)] = kind
        armies = np.asarray(state.armies)
        info = self.game.get_info(state)
        observations = self.game.get_observations(state)
        normalized = []
        for player in range(self.players):
            visible = ~(np.asarray(observations.fog_cells[player]) |
                        np.asarray(observations.structures_in_fog[player]))
            view_kinds = np.where(visible, kinds, -1)
            view_kinds[np.asarray(observations.structures_in_fog[player])] = -2
            normalized.append({
                "visible": visible.reshape(-1).tolist(),
                "kinds": view_kinds.reshape(-1).tolist(),
                "owners": np.where(visible, owners, -1).reshape(-1).tolist(),
                "armies": np.asarray(observations.armies[player]).reshape(-1).tolist(),
                "myLand": int(observations.owned_land_count[player]),
                "myArmy": int(observations.owned_army_count[player]),
                "oppLand": int(observations.opponent_land_count[player]),
                "oppArmy": int(observations.opponent_army_count[player]),
            })
        return {
            "turn": int(state.time), "winner": int(state.winner),
            "finished": self.finished,
            "tiles": [
                {"kind": int(kind), "owner": int(owner), "army": int(army)}
                for kind, owner, army in zip(kinds.flat, owners.flat, armies.flat)
            ],
            "generals": [int(row) * self.width + int(col)
                         for row, col in np.asarray(state.general_positions)],
            "alive": (~np.asarray(state.eliminated)).tolist(),
            "totals": [{"land": int(info.land[player]), "army": int(info.army[player])}
                       for player in range(self.players)],
            "observations": normalized,
        }

    def compare(self):
        self.expected = self.normalized()
        difference = first_difference(self.expected, self.actual)
        if difference:
            self.fail(difference)
        self.states += 1
        self.cells += self.width * self.height
        self.observation_cells += self.width * self.height * self.players

    def fail(self, difference):
        self.failure.parent.mkdir(parents=True, exist_ok=True)
        self.failure.write_text(json.dumps({
            "case": self.name, "difference": difference, "initial": self.initial,
            "history": self.history, "python": self.expected, "nim": self.actual,
        }, indent=2) + "\n")
        raise AssertionError(f"{self.name}, request {len(self.history)}: {difference}; {self.failure}")

    def advance(self, actions, operation="step", native_moves=None):
        message = {"op": operation, "actions": actions}
        if native_moves is not None:
            message = {"op": operation, "moves": native_moves}
        self.history.append(message)
        self.actual = self.driver.request(message)
        if operation == "step" or not self.finished:
            self.state, _ = self.game.step(
                self.state, self.jnp.asarray(actions, dtype=self.jnp.int32),
                general_trade=True,
            )
            self.finished = int(self.state.winner) >= 0
            if operation == "tick" and int(self.state.time) >= self.config["maxTurns"]:
                self.finished = True
        self.compare()
        self.steps += 1


def board(players=2, turn=0, limit=2000, width=SIZE, height=SIZE):
    """Create a shared board fixture without invoking either map generator."""
    world = {
        "config": {"width": width, "height": height, "players": players,
                   "seed": 0, "maxTurns": limit},
        "tiles": [{"kind": 0, "owner": -1, "army": 0} for _ in range(width * height)],
        "generals": [0] * players, "alive": [True] * players,
        "turn": turn, "winner": -1, "finished": False,
    }
    homes = [
        (1, 1), (height - 2, width - 2), (1, width - 2), (height - 2, 1),
        (1, width // 3), (1, width * 2 // 3),
        (height - 2, width // 3), (height - 2, width * 2 // 3),
        (height // 2, 1), (height // 2, width - 2),
    ]
    assert players in PLAYER_COUNTS and len(set(homes)) == len(homes)
    for player, (row, col) in enumerate(homes[:players]):
        place(world, row, col, player, 1, 3)
        world["generals"][player] = row * width + col
    return world


def place(world, row, col, owner, army, kind=0):
    index = row * world["config"]["width"] + col
    world["tiles"][index] = {"kind": kind, "owner": owner, "army": army}


def general(world, player, row, col, army):
    old = world["generals"][player]
    world["tiles"][old] = {"kind": 0, "owner": -1, "army": 0}
    place(world, row, col, player, army, 3)
    world["generals"][player] = row * world["config"]["width"] + col


def move(row, col, direction, half=False):
    return [0, row, col, direction, int(half)]


def scenarios():
    """Cover ordering, combat boundaries, trade timing, fog, and terminal ticks."""
    for width, height in ((18, 21), (21, 18)):
        for players in (2, 4, 10):
            world = board(players, width=width, height=height)
            general(world, 0, 0, 0, 10)
            general(world, 1, height - 1, width - 1, 10)
            place(world, 0, width - 2, 0, 8)
            place(world, 0, width - 1, -1, 0, 1)
            place(world, 1, width - 1, -1, 4, 2)
            place(world, height - 1, 0, 1, 6)
            place(world, height // 2, width // 2, -1, 0, 1)
            place(world, height // 2, width // 2 + 1, -1, 40, 2)
            passive = [PASS] * (players - 2)
            yield f"rectangle-{width}x{height}-{players}p-edges-fog", world, [
                [move(0, width - 2, 1), move(height - 1, 0, 0)] + passive,
                [move(1, width - 2, 3), move(height - 2, 0, 3)] + passive,
                [move(0, width - 2, 0), move(height - 1, 0, 1)] + passive,
                [PASS] * players,
            ]
    for turn in (0, 1, 48, 49):
        world = board(turn=turn)
        place(world, 4, 4, 0, 0)
        place(world, 4, 5, 0, 7, 2)
        place(world, 8, 8, -1, 40, 2)
        place(world, 8, 9, -1, 0, 1)
        yield f"growth-{turn}", world, [[PASS, PASS]] * 3
    for half in (False, True):
        for defender in (0, 4, 5, 12):
            world = board()
            place(world, 5, 4, 0, 11)
            place(world, 5, 5, 1, defender)
            yield f"combat-half-{half}-defender-{defender}", world, [
                [move(5, 4, 3, half), PASS]
            ]
    for turn in (0, 1):
        for first, second in ((25, 40), (30, 30)):
            world = board(turn=turn)
            place(world, 5, 4, 0, first)
            place(world, 5, 6, 1, second)
            place(world, 5, 5, -1, 20)
            yield f"contested-{turn}-{first}-{second}", world, [
                [move(5, 4, 3), move(5, 6, 2)]
            ]
    world = board()
    place(world, 5, 4, 0, 25)
    place(world, 5, 5, 1, 40)
    yield "chase", world, [[move(5, 4, 3), move(5, 5, 3)]]
    yield "head-on", world, [[move(5, 4, 3), move(5, 5, 2, True)]]
    world = board(4)
    for player, (row, col) in enumerate(((5, 5), (5, 6), (6, 6), (6, 5))):
        place(world, row, col, player, 20 + player)
    yield "four-way-chase-cycle", world, [[
        move(5, 5, 3), move(5, 6, 1), move(6, 6, 2), move(6, 5, 0)
    ]]
    for turn in (1, 49):
        world = board(turn=turn)
        general(world, 1, 5, 5, 3)
        place(world, 5, 4, 0, 30)
        place(world, 8, 8, 1, 9, 2)
        place(world, 8, 7, 1, 4)
        yield f"capture-no-income-{turn}", world, [
            [move(5, 4, 3), PASS], [move(5, 5, 3), PASS], [PASS, PASS]
        ]
    for half in (False, True):
        world = board(turn=10)
        general(world, 0, 0, 0, 5)
        general(world, 1, 0, 7, 7)
        place(world, 0, 6, 0, 41)
        place(world, 1, 0, 1, 30)
        place(world, 3, 3, 0, 9)
        place(world, 4, 4, 1, 4)
        yield f"mutual-trade-half-{half}", world, [
            [move(0, 6, 3, half), move(1, 0, 0)], [PASS, PASS]
        ]
    world = board(turn=10)
    general(world, 0, 5, 5, 10)
    general(world, 1, 5, 6, 30)
    yield "mutual-general-launch-reserves", world, [[move(5, 5, 3), move(5, 6, 2)]]
    for disrupt in (False, True):
        world = board(4, turn=10)
        general(world, 0, 0, 0, 5)
        general(world, 2, 0, 7, 7)
        place(world, 0, 6, 0, 40)
        place(world, 1, 0, 2, 30)
        if disrupt:
            place(world, 1, 6, 1, 38)
            third = move(1, 6, 0)
        else:
            place(world, 4, 4, 0, 9)
            place(world, 4, 5, 1, 12)
            third = move(4, 5, 2)
        yield f"ffa-trade-after-earlier-attack-{disrupt}", world, [[
            move(0, 6, 3), third, move(1, 0, 0), PASS
        ]]
    for army in (0, 1, 2):
        world = board()
        place(world, 5, 4, 0, army)
        place(world, 5, 5, 1, 20)
        yield f"small-source-chase-{army}", world, [[move(5, 4, 3), move(5, 5, 3)]]
    world = board()
    place(world, 0, 5, 0, 30)
    place(world, 1, 5, 1, 20)
    yield "offboard-intent-chased", world, [[move(0, 5, 0), move(1, 5, 0)]]
    world = board()
    place(world, 5, 4, 1, 50)
    place(world, 5, 5, 1, 10)
    yield "wrong-owner-intent", world, [[move(5, 4, 3), move(5, 5, 3)]]
    world = board()
    place(world, 5, 4, 0, 50)
    place(world, 5, 5, -1, 0, 1)
    yield "mountain-intent", world, [[move(5, 4, 3), PASS]]
    world = board(4)
    general(world, 0, 5, 4, 40)
    place(world, 4, 4, 0, 10)
    place(world, 5, 5, 1, 30)
    yield "friendly-general-defense", world, [[move(4, 4, 1), move(5, 5, 2), PASS, PASS]]
    for players in PLAYER_COUNTS:
        world = board(players, turn=49)
        general(world, 0, 5, 5, 3)
        place(world, 5, 4, players - 1, 30)
        place(world, 8, 8, 0, 9, 2)
        actions = [PASS] * players
        actions[-1] = move(5, 4, 3)
        yield f"highest-seat-captures-first-{players}p", world, [actions]
    for turn in (0, 1):
        world = board(10, turn=turn)
        place(world, 5, 4, 0, 30)
        place(world, 5, 6, 9, 30)
        actions = [PASS] * 10
        actions[0], actions[9] = move(5, 4, 3), move(5, 6, 2)
        yield f"ten-player-seat-ties-{turn}", world, [actions]
    world = board(10, turn=49)
    actions = [PASS] * 10
    for pair in range(5):
        row = 3 + pair * 2
        attacker, victim = pair * 2, pair * 2 + 1
        general(world, victim, row, 6, 2)
        place(world, row, 5, attacker, 30)
        actions[attacker] = move(row, 5, 3)
    yield "ten-player-five-simultaneous-captures", world, [actions, [PASS] * 10]
    world = board(10, turn=49)
    actions = []
    for pair, (row, col) in enumerate(((3, 2), (3, 6), (6, 2), (6, 6), (9, 4))):
        first, second = pair * 2, pair * 2 + 1
        general(world, first, row, col, 20 + first)
        general(world, second, row, col + 1, 20 + second)
        place(world, 0, first + 1, first, 9)
        place(world, 0, second + 1, second, 4)
        actions.extend((move(row, col, 3), move(row, col + 1, 2)))
    yield "ten-player-five-simultaneous-trades", world, [actions, [PASS] * 10]
    world = board(10)
    actions = []
    cycle = ((4, 4), (4, 5), (4, 6), (4, 7), (5, 7),
             (6, 7), (6, 6), (6, 5), (6, 4), (5, 4))
    for player, (row, col) in enumerate(cycle):
        target_row, target_col = cycle[(player + 1) % len(cycle)]
        place(world, row, col, player, 20 + player)
        direction = DIRECTIONS.index((target_row - row, target_col - col))
        actions.append(move(row, col, direction))
    yield "ten-player-chase-cycle", world, [actions]


def wire_observation(snapshot, player, height, width):
    """Translate independently normalized fog into the original Agent interface."""
    observation = snapshot["observations"][player]
    kinds = [{-2: 5, -1: 0, 0: 1, 1: 2, 2: 3, 3: 4}[kind]
             for kind in observation["kinds"]]
    owners = [0 if owner == -1 else 1 if owner == player else 2
              for owner in observation["owners"]]
    def rows(values):
        return [values[start:start + width] for start in range(0, len(values), width)]
    return types.SimpleNamespace(
        H=height, W=width, turn=snapshot["turn"],
        my_land=observation["myLand"], my_army=observation["myArmy"],
        opp_land=observation["oppLand"], opp_army=observation["oppArmy"],
        type_grid=rows(kinds), owner_grid=rows(owners), army_grid=rows(observation["armies"]),
    )


def random_actions(snapshot, rng, players):
    """Exercise both legal moves and protocol-shaped invalid intents."""
    actions = []
    for player in range(players):
        if rng.random() < 0.15:
            actions.append(PASS)
            continue
        owned = [i for i, tile in enumerate(snapshot["tiles"]) if tile["owner"] == player]
        source = rng.choice(owned) if owned and rng.random() < 0.8 else rng.randrange(SIZE * SIZE)
        row, col = divmod(source, SIZE)
        actions.append(move(row, col, rng.randrange(4), rng.randrange(2)))
    return actions


def fuzz_world(seed, players):
    """Seed varied shared states; this does not claim map-generator equivalence."""
    rng = random.Random(seed)
    world = board(players, turn=rng.choice((0, 1, 48, 49, 98, 99)))
    generals = set(world["generals"])
    for index in range(SIZE * SIZE):
        if index in generals:
            world["tiles"][index]["army"] = rng.randrange(1, 100)
            continue
        kind = rng.choices((0, 1, 2), (80, 12, 8))[0]
        owner = -1 if kind == 1 else rng.randrange(-1, players)
        army = 0 if kind == 1 else rng.randrange(0, 100)
        world["tiles"][index] = {"kind": kind, "owner": owner, "army": army}
    return world


def baseline_match(check, agent_class, initial, seed, turns):
    """Run original Python Agents separately on each engine's observations."""
    players = initial["config"]["players"]
    check.begin(f"original-expander-{players}p-seed-{seed}", initial)
    python_agents = [agent_class(player, check.height, check.width) for player in range(players)]
    nim_agents = [agent_class(player, check.height, check.width) for player in range(players)]
    while not check.finished and int(check.state.time) < turns:
        actions = []
        for player in range(players):
            python_action = list(python_agents[player].act(wire_observation(
                check.expected, player, check.height, check.width,
            )))
            nim_action = list(nim_agents[player].act(wire_observation(
                check.actual, player, check.height, check.width,
            )))
            if python_action != nim_action:
                check.fail(f"original Agent actions differ for player {player}: {python_action} != {nim_action}")
            actions.append(python_action)
            check.action_checks += 1
        check.advance(actions, "tick")
        check.baseline_steps += 1
    check.games.append({
        "agents": "original-expander", "players": players, "seed": seed,
        "width": check.width, "height": check.height,
        "turns": int(check.state.time), "winner": int(check.state.winner),
        "finished": check.finished,
    })
    print(f"PASS {check.name}: {int(check.state.time)} ticks, winner {int(check.state.winner)}", flush=True)


def native_actions(moves, width):
    """Translate native geometry for Python while Nim receives its flat moves."""
    actions = []
    for action in moves:
        source, target = action["source"], action["target"]
        if source == -1 and target == -1:
            actions.append(PASS)
            continue
        row, col = divmod(source, width)
        target_row, target_col = divmod(target, width)
        offset = (target_row - row, target_col - col)
        if offset not in DIRECTIONS:
            raise AssertionError(f"Native bot returned noncardinal move: {action}")
        actions.append(move(row, col, DIRECTIONS.index(offset), action["half"]))
    return actions


def native_match(check, initial, seed, turns):
    """Apply the shipping Nim bot's exact flat moves to both real engines."""
    players = initial["config"]["players"]
    check.begin(f"native-bots-{players}p-seed-{seed}", initial)
    while not check.finished and int(check.state.time) < turns:
        moves = check.driver.request({"op": "choose"})["moves"]
        check.advance(native_actions(moves, check.width), "tick", moves)
        check.native_steps += 1
    winner = int(check.state.winner)
    if winner >= 0:
        check.native_conquests += 1
    check.games.append({
        "agents": "native-bots", "players": players, "seed": seed,
        "width": check.width, "height": check.height,
        "turns": int(check.state.time), "winner": winner,
        "finished": check.finished,
    })
    if check.finished:
        frozen = check.actual
        moves = [{"source": -1, "target": -1, "half": False} for _ in range(players)]
        for source, tile in enumerate(frozen["tiles"]):
            if tile["owner"] < 0 or tile["army"] < 2:
                continue
            player = tile["owner"]
            if moves[player]["source"] >= 0:
                continue
            row, col = divmod(source, check.width)
            for dr, dc in DIRECTIONS:
                nr, nc = row + dr, col + dc
                if not (0 <= nr < check.height and 0 <= nc < check.width):
                    continue
                target = nr * check.width + nc
                if frozen["tiles"][target]["kind"] != 1:
                    moves[player] = {"source": source, "target": target, "half": False}
                    break
        for _ in range(3):
            check.advance(native_actions(moves, check.width), "tick", moves)
            if check.actual != frozen:
                check.fail("Production tick changed a finished native match")
            check.frozen_ticks += 1
    print(f"PASS {check.name}: {int(check.state.time)} ticks, winner {winner}", flush=True)


def new_initial(driver, players, seed, limit):
    """Share the native map with Python without claiming matching generators."""
    config = {"players": players, "seed": seed, "maxTurns": limit}
    snapshot = driver.request({"op": "new", "config": config})
    initial = {key: snapshot[key] for key in
               ("tiles", "generals", "alive", "turn", "winner", "finished")}
    initial["config"] = snapshot["config"]
    return initial


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", type=Path, default=ROOT / "build" / "reference_runner")
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--quick", action="store_true", help="Short smoke run, not complete seeded games.")
    parser.add_argument("--seeds", default="7,23")
    parser.add_argument("--players", default=",".join(map(str, PLAYER_COUNTS)),
                        help="Comma-separated player counts from 2 through 10.")
    parser.add_argument("--turns", type=int, default=2000)
    parser.add_argument("--fuzz-cases", type=int, default=32)
    parser.add_argument("--fuzz-turns", type=int, default=24)
    parser.add_argument("--failure", type=Path, default=ROOT / "build" / "reference_failure.json")
    parser.add_argument("--report", type=Path, default=ROOT / "build" / "reference_report.json")
    args = parser.parse_args()
    try:
        player_counts = tuple(dict.fromkeys(
            int(value) for value in args.players.split(",")
        ))
    except ValueError:
        parser.error("--players must contain player counts from 2 through 10")
    if not player_counts or any(value not in PLAYER_COUNTS for value in player_counts):
        parser.error("--players must contain player counts from 2 through 10")
    args.report.unlink(missing_ok=True)
    args.failure.unlink(missing_ok=True)
    if not args.no_build:
        args.runner.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([
            "nim", "c", "--skipParentCfg:on", "--skipProjCfg:on", "-d:release",
            f"--path:{ROOT / 'src'}",
            f"--nimcache:{args.runner.parent / (args.runner.name + '_nimcache')}",
            f"--out:{args.runner}", str(ROOT / "tools" / "reference_runner.nim"),
        ], check=True, cwd=ROOT)
    game, agent_class = load_reference()
    driver = Driver(args.runner.resolve())
    check = Comparison(game, driver, args.failure)
    try:
        for name, initial, turns in scenarios():
            check.begin(name, initial)
            for actions in turns:
                check.advance(actions)
        print(f"PASS {check.cases} focused scenarios", flush=True)
        fuzz_cases = 4 if args.quick else args.fuzz_cases
        for players in player_counts:
            for seed in range(fuzz_cases):
                check.begin(f"random-{players}p-seed-{seed}", fuzz_world(seed, players))
                rng = random.Random(seed + players * 1000)
                for _ in range(args.fuzz_turns):
                    check.advance(random_actions(check.actual, rng, players))
            print(f"PASS {fuzz_cases} random {players}-player trajectories", flush=True)
        seeds = [7] if args.quick else [int(seed) for seed in args.seeds.split(",")]
        turns = min(args.turns, 120) if args.quick else args.turns
        for players in player_counts:
            for seed in seeds:
                initial = new_initial(driver, players, seed, args.turns)
                baseline_match(check, agent_class, initial, seed, turns)
        for players in player_counts:
            for seed in seeds:
                initial = new_initial(driver, players, seed, args.turns)
                native_match(check, initial, seed, turns)
        initial = board(limit=2)
        check.begin("production-turn-cap-draw-and-freeze", initial)
        for _ in range(4):
            check.advance([PASS, PASS], "tick")
        report = {
            "result": "PASS", "cases": check.cases, "transitions": check.steps,
            "states": check.states, "board_cells": check.cells,
            "observation_cells": check.observation_cells,
            "original_agent_ticks": check.baseline_steps,
            "independent_agent_action_comparisons": check.action_checks,
            "native_bot_ticks": check.native_steps,
            "native_conquests": check.native_conquests,
            "postgame_frozen_ticks": check.frozen_ticks,
            "quick": args.quick,
            "player_counts": list(player_counts),
            "reference_revision": json.loads((REFERENCE / "manifest.json").read_text())["revision"],
            "games": check.games,
            "scope": "classic FFA shared boards and actions; map generation excluded",
        }
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2), flush=True)
        print(f"Report: {args.report}", flush=True)
    except Exception as error:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps({
            "result": "FAIL", "error": str(error),
            "case": getattr(check, "name", None), "transitions": check.steps,
            "failure_replay": str(args.failure) if args.failure.exists() else None,
        }, indent=2) + "\n")
        raise
    finally:
        driver.close()


if __name__ == "__main__":
    main()
