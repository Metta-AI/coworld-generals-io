"""Coworld boundary for classic 1v1, three-to-eight-player FFA and castle building."""

from functools import partial

import jax
import jax.numpy as jnp
import numpy as np

from generals import GeneralsEnv
from generals.core import game
from generals.core.match import make_board, make_transition
from generals.modifiers import build_castles

from .ffa_map import generate_ffa_grid
from .protocol import PASS, VERSION

RULESET = "classic"


@partial(jax.jit, static_argnames=("general_trade",))
def executed_moves(state, actions, general_trade=False):
    """Receipts for the base moves, using the engine's actual resolution order.

    Observe each action separately, before growth or the other action can mask
    its effects.
    """
    _, executed = game.resolve_moves(state, actions, general_trade=general_trade)
    return executed


@jax.jit
def build_receipts(state, actions):
    """Measure construction before an opponent can capture the new castle."""
    built_state, moves = build_castles.apply_build_actions(state, actions)
    rows, cols = actions[:, 1], actions[:, 2]
    owns = state.ownership[jnp.arange(actions.shape[0]), rows, cols]
    built = (actions[:, 0] == 2) & owns & ~state.castles[rows, cols] & built_state.castles[rows, cols]
    return built, executed_moves(built_state, moves)


_build_cost_grid = jax.jit(build_castles.build_cost_grid)


class Match:
    engine_name = "jax"

    def __init__(self, seed: int, num_players: int = 2, ruleset: str = RULESET):
        if not 2 <= num_players <= 8:
            raise ValueError("two to eight players are required")
        if ruleset not in ("classic", "build_castles"):
            raise ValueError("unknown ruleset")
        if ruleset == "build_castles" and num_players != 2:
            raise ValueError("castle-building requires two players")
        self.num_players = num_players
        self.ruleset = ruleset
        self.is_ffa = num_players > 2
        self.neutralize_at = np.full(num_players, -1, dtype=np.int32)
        self.idle_ticks = 0
        self.afk_warning = np.zeros(num_players, dtype=bool)
        self.end_reason = "general_capture"
        # The env owns transition rules. FFA samples its board separately using
        # the ranked game's player-count-dependent map and placement rules.
        self.env = GeneralsEnv(
            min_grid_size=18, max_grid_size=21, pad_to=21, truncation=50002 if num_players > 2 else 2000,
            mountain_density_range=(0.24, 0.26), min_generals_distance=17,
            num_players=num_players, build_castles=ruleset == "build_castles", deathtouch_turn=None,
            general_trade=ruleset == "classic",
        )
        self.state = (
            game.create_initial_state(jnp.asarray(generate_ffa_grid(seed, num_players)), teams=self.env.teams)
            if num_players > 2 else make_board(self.env, seed)
        )
        self.transition = jax.jit(make_transition(self.env))
        self.last_move_executed = [None] * num_players
        self.last_build_executed = [None] * num_players
        # Compile before /healthz and before player deadlines begin.
        passes = jnp.array([PASS] * num_players, dtype=jnp.int32)
        jax.block_until_ready(self.transition(self.state, passes))
        jax.block_until_ready(executed_moves(self.state, passes, general_trade=self.env.general_trade))
        if ruleset == "build_castles":
            jax.block_until_ready(build_receipts(self.state, passes))
        jax.block_until_ready(game.get_observation(self.state, 0))
        jax.block_until_ready(game.get_observations(self.state))
        for slot in range(num_players):
            if ruleset == "build_castles":
                jax.block_until_ready(_build_cost_grid(self.state, slot))
        self.height, self.width = self.state.armies.shape

    @property
    def turn(self):
        return int(self.state.time)

    @property
    def active_slots(self) -> list[int]:
        return np.flatnonzero(~np.asarray(self.state.eliminated)).tolist()

    def observation(self, slot: int) -> dict:
        return self._encode_observation(slot, game.get_observation(self.state, slot), np.asarray(self.state.ownership))

    def observations(self) -> list[dict]:
        observations = jax.tree.map(np.asarray, game.get_observations(self.state))
        ownership = np.asarray(self.state.ownership)
        return [self._encode_observation(slot, jax.tree.map(lambda value: value[slot], observations), ownership)
                for slot in range(self.num_players)]

    def _encode_observation(self, slot: int, obs, ownership: np.ndarray) -> dict:
        kinds = np.ones((self.height, self.width), dtype=np.int32)
        for name, value in (
            ("fog_cells", 0),
            ("structures_in_fog", 5),
            ("mountains", 2),
            ("castles", 3),
            ("generals", 4),
        ):
            kinds[np.asarray(getattr(obs, name), dtype=bool)] = value
        owners = np.zeros_like(kinds)
        owners[np.asarray(obs.owned_cells)] = 1
        owners[np.asarray(obs.opponent_cells)] = 2
        visible_owners = np.zeros_like(kinds)
        visible = ~(np.asarray(obs.fog_cells) | np.asarray(obs.structures_in_fog))
        for owner in range(self.num_players):
            visible_owners[ownership[owner] & visible] = owner + 1
        observation = {
            "type": "observation",
            "protocol_version": VERSION,
            "slot": slot,
            "turn": self.turn,
            "last_move_executed": self.last_move_executed[slot],
            "last_build_executed": self.last_build_executed[slot],
            "ruleset": self.ruleset,
            "eliminated": bool(np.asarray(self.state.eliminated)[slot]),
            "afk_warning": bool(self.afk_warning[slot]),
            "height": self.height,
            "width": self.width,
            "my_land": int(obs.owned_land_count),
            "my_army": int(obs.owned_army_count),
            "opp_land": int(obs.opponent_land_count),
            "opp_army": int(obs.opponent_army_count),
            "type_grid": kinds.tolist(),
            "owner_grid": owners.tolist(),
            "visible_owner_grid": visible_owners.tolist(),
            "army_grid": np.asarray(obs.armies).tolist(),
        }
        if self.ruleset == "build_castles":
            eligible = np.asarray(obs.owned_cells) & (kinds == 1)
            costs = np.asarray(_build_cost_grid(self.state, slot))
            observation["build_cost_grid"] = np.where(eligible, costs, 0).tolist()
        return observation

    @property
    def kills(self) -> list[int]:
        return np.bincount(np.asarray(self.state.captured_by) + 1, minlength=self.num_players + 1)[1:].tolist()

    def standings(self, winner: int) -> dict:
        """Official FFA Survival order: kill/win eligibility, then elimination order.

        Scores encode that order for the platform ranker; they are not stars.
        """
        deaths = np.asarray(self.state.death_order)
        qualified = [count > 0 or slot == winner for slot, count in enumerate(self.kills)]
        order = sorted(range(self.num_players), key=lambda slot: (
            qualified[slot], slot == winner, int(deaths[slot])
        ), reverse=True)
        placements = [order.index(slot) + 1 for slot in range(self.num_players)]
        return {
            "placements": placements, "kills": self.kills,
            "captured_by": np.asarray(self.state.captured_by).tolist(),
            "elimination_order": sorted(np.flatnonzero(deaths >= 0).tolist(), key=lambda slot: int(deaths[slot])),
            "scores": [1 if place == 1 else -(place - 1) / (self.num_players - 1) for place in placements],
        }

    def adjudicate(self, frame: dict) -> int:
        """The official idle/long-game tiebreak: army, land, then higher seat."""
        order = sorted(self.active_slots, key=lambda slot: (frame["army"][slot], frame["land"][slot], slot))
        for slot in order[:-1]:
            self.state = game.surrender(self.state, slot)
        winner = order[-1]
        self.state = self.state._replace(winner=jnp.int32(winner))
        # Game._ensureFinalSurrenderRecordedAsCapture credits the final death.
        last = int(np.argmax(np.asarray(self.state.death_order)))
        if self.state.captured_by[last] < 0:
            self.state = self.state._replace(captured_by=self.state.captured_by.at[last].set(winner))
        return winner

    def frame(self) -> dict:
        s = self.state
        kinds = np.ones((self.height, self.width), dtype=np.int32)
        for mask, value in ((s.mountains, 2), (s.castles, 3), (s.generals, 4)):
            kinds[np.asarray(mask)] = value
        owners = np.zeros_like(kinds)
        ownership = np.asarray(s.ownership)
        for slot in range(self.num_players):
            owners[ownership[slot]] = slot + 1
        info = game.get_info(s)
        return {
            "turn": self.turn,
            "type_grid": kinds.tolist(),
            "owner_grid": owners.tolist(),
            "army_grid": np.asarray(s.armies).tolist(),
            "army": np.asarray(info.army).tolist(),
            "land": np.asarray(info.land).tolist(),
            "eliminated": np.asarray(s.eliminated).tolist(),
            "kills": self.kills,
            "neutralize_in": np.where(np.asarray(info.land) > 0,
                                      np.maximum(-1, self.neutralize_at - self.turn), -1).tolist(),
        }

    def advance(self, actions: list[list[int]]) -> int:
        if len(actions) != self.num_players:
            raise ValueError("one action per player is required")
        allowed = (0, 1, 2) if self.ruleset == "build_castles" else (0, 1)
        if any(action[0] not in allowed for action in actions):
            raise ValueError("classic rules accept only moves and passes")
        batch = jnp.array(actions, dtype=jnp.int32)
        if self.ruleset == "build_castles":
            built, executed = build_receipts(self.state, batch)
            self.last_build_executed = [bool(built[s]) if actions[s][0] == 2 else None for s in range(self.num_players)]
        else:
            executed = executed_moves(self.state, batch, general_trade=self.env.general_trade)
        previous_state = self.state
        self.state, info = self.transition(self.state, batch)
        executed = np.asarray(executed)
        self.last_move_executed = [bool(executed[s]) if actions[s][0] == 0 else None for s in range(self.num_players)]
        winner = int(info.winner) if bool(info.is_done) else -1
        if self.is_ffa:
            self.afk_warning[:] = False
            if winner < 0 and 99 <= self.turn <= 121:
                previous_land = np.asarray(game.get_info(previous_state).land)
                ownership = np.asarray(self.state.ownership)
                structures = np.asarray(self.state.castles)
                for slot in self.active_slots:
                    own = ownership[slot]
                    border = np.asarray(game.get_visibility(self.state.ownership[slot]))
                    sees_opponent = bool(np.any(border & np.any(np.delete(ownership, slot, axis=0), axis=0)))
                    if previous_land[slot] < 11 and not sees_opponent and not np.any(own & structures):
                        if self.turn < 121:
                            self.afk_warning[slot] = True
                        else:
                            self.forfeit([slot])
                            if len(self.active_slots) == 1:
                                winner = self.active_slots[0]
                                self.end_reason = "forfeit"
                                break
            for slot in np.flatnonzero(self.neutralize_at == self.turn):
                self.state = game.neutralize(self.state, int(slot))
            self.idle_ticks = 0 if any(self.last_move_executed) else self.idle_ticks + 1
            if winner < 0 and (self.idle_ticks > 2000 or self.turn > 50001):
                self.end_reason = "idle_limit" if self.idle_ticks > 2000 else "turn_limit"
                previous_info = game.get_info(previous_state)
                winner = self.adjudicate({
                    "army": np.asarray(previous_info.army), "land": np.asarray(previous_info.land)
                })
            if winner >= 0:
                self.state = self.state._replace(winner=jnp.int32(winner))
                last = int(np.argmax(np.asarray(self.state.death_order)))
                if self.state.captured_by[last] < 0:
                    self.state = self.state._replace(captured_by=self.state.captured_by.at[last].set(winner))
        return winner

    def forfeit(self, slots: list[int]) -> int:
        """Surrender FFA seats with a 50-tick capture window.

        Classic/build modes retain their immediate timeout neutralization.
        """
        if any(type(slot) is not int or not 0 <= slot < self.num_players for slot in slots):
            raise ValueError("invalid forfeiting player")
        if self.is_ffa:
            for slot in slots:
                if len(self.active_slots) <= 1:
                    break
                if slot in self.active_slots:
                    self.state = game.surrender(self.state, slot)
                    self.neutralize_at[slot] = self.turn + 50
            return self.active_slots[0] if len(self.active_slots) == 1 else -1
        s = self.state
        ownership = np.asarray(s.ownership).copy()
        eliminated = np.asarray(s.eliminated).copy()
        neutralized = np.zeros(s.armies.shape, dtype=bool)
        for slot in slots:
            neutralized |= ownership[slot]
            ownership[slot] = False
            eliminated[slot] = True
        active = np.flatnonzero(~eliminated)
        winner = int(active[0]) if len(active) == 1 else -1
        self.state = s._replace(
            ownership=jnp.asarray(ownership),
            ownership_neutral=s.ownership_neutral | jnp.asarray(neutralized),
            castles=s.castles | (s.generals & jnp.asarray(neutralized)),
            generals=s.generals & ~jnp.asarray(neutralized),
            eliminated=jnp.asarray(eliminated),
            winner=jnp.int32(winner),
        )
        return winner
