# JAX engine and research interfaces

`generals` is the Python import package; its distribution remains `generals-bots`
(versioned independently of Coworld releases). Install from the repository root
with `pip install -e .`. Python 3.11 or later is required; CI uses Python 3.12.

For browser play, hosted games, BASIC policies, and league scoring, start with
[the Softmax adapter](../integrations/softmax/README.md).

## Engine boundaries

- [`core/game.py`](core/game.py) owns board state, moves, captures, growth, and fog observations.
- [`core/env.py`](core/env.py) exposes `GeneralsEnv` for reinforcement learning,
  with pooled starting states and automatic reset after termination or truncation.
- [`core/match.py`](core/match.py) exposes `make_board` and `make_transition`
  for a single episode without allocating the training pool.
- [`modifiers/`](modifiers) contains optional castle-building and Deathtouch rules.
- [`agents/`](agents) contains JAX agents; [`gui/`](gui) contains the Pygame desktop tools.
- [`remote/`](remote) connects research agents to external generals.io lobbies.

The hosted adapter's [`Match`](../integrations/softmax/engine.py) composes these
transitions, samples ranked FFA maps separately, and implements FFA adjudication.
`GeneralsEnv(num_players=4)` alone does not select the hosted FFA map or scoring rules.
The research environment also supports teams; hosted variants use independent players.

The research preset `GeneralsEnv(mode="competition")` enables castle building
and Deathtouch at tick 800. The hosted variant named `competition` uses classic
capture-only rules with Deathtouch disabled. See [hosted variants](../integrations/softmax/VARIANTS.md#modes).

## Game loop

### Single environment

```python
import jax.numpy as jnp
import jax.random as jrandom

from generals import GeneralsEnv, get_observation
from generals.agents import RandomAgent, ExpanderAgent

# Create environment (customize grid size and truncation)
env = GeneralsEnv(grid_dims=(10, 10), truncation=500, pool_size=32)

# Create agents
agent_0 = RandomAgent()
agent_1 = ExpanderAgent()

# Initialize — reset returns the auto-reset pool plus the first state
key = jrandom.PRNGKey(42)
pool, state = env.reset(key)

# Game loop
while True:
    # Get observations
    obs_0 = get_observation(state, 0)
    obs_1 = get_observation(state, 1)

    # Get actions
    key, k1, k2 = jrandom.split(key, 3)
    action_0 = agent_0.act(obs_0, k1)
    action_1 = agent_1.act(obs_1, k2)
    actions = jnp.stack([action_0, action_1])

    # Step environment (auto-resets from the pre-generated pool)
    timestep, state = env.step(state, actions, pool)

    if timestep.terminated or timestep.truncated:
        break

print(f"Winner team (-1 for a draw): {int(timestep.info.winner)}")
```

### Vectorized environments

See [the complete vectorized example](../examples/vectorized_example.py) for
`jax.vmap` over states, observations, agent actions, and environment steps.
The pool is shared; each environment keeps its own state and random key.

### Teams and free-for-all

The same env plays 1v1 (the default), N-player free-for-all, and team games:

```python
env = GeneralsEnv(grid_dims=(15, 15))                   # 1v1
env = GeneralsEnv(grid_dims=(15, 15), num_players=4)    # 4-player free-for-all
env = GeneralsEnv(grid_dims=(15, 15), teams=[0, 0, 1, 1])   # 2v2: players 0+1 vs 2+3
```

With N players, actions are `(N, 5)`, `state.ownership` is `(N, H, W)`, and
observations and rewards are stacked `(N, ...)`. Rules beyond 1v1:

* Moving onto a **teammate's** cell pools the armies and hands the cell to the mover.
* **Capturing a general** transfers all of the victim's cells to the capturer with
  every army halved (rounded up); the general becomes a castle and the victim is
  eliminated (their actions are ignored from then on). The game goes on while
  another team is alive.
* A team loses only when **every** one of its generals has fallen; the **last
  team standing** wins. `info.winner` is the winning team id (the player index
  in 1v1 / free-for-all), and every player on that team gets reward `+1`,
  everyone else `-1`.
* **Sight is shared** within a team. Observations carry `allied_cells`,
  `allied_land_count` and `allied_army_count` (all zero when you have no
  teammate); `opponent_*` covers every enemy team together.

See [the multiplayer example](../examples/multiplayer_example.py) for batched 2v2 / FFA / 1v1 games under `jax.jit`.

## Observations and actions

### Observation

Each player receives an `Observation` with these fields:

| Field | Shape | Description |
|-------|-------|-------------|
| `armies` | `(H,W)` | Army counts in visible cells |
| `generals` | `(H,W)` | Mask of visible generals |
| `castles` | `(H,W)` | Mask of visible castles (formerly `cities` — a deprecated alias remains) |
| `mountains` | `(H,W)` | Mask of visible mountains |
| `owned_cells` | `(H,W)` | Mask of cells you own |
| `opponent_cells` | `(H,W)` | Mask of opponent's visible cells |
| `neutral_cells` | `(H,W)` | Mask of neutral visible cells |
| `fog_cells` | `(H,W)` | Mask of fog (unexplored) cells |
| `structures_in_fog` | `(H,W)` | Mask of castles/mountains in fog |
| `owned_land_count` | scalar | Total cells you own |
| `owned_army_count` | scalar | Total armies you have |
| `opponent_land_count` | scalar | Opponent's cell count |
| `opponent_army_count` | scalar | Opponent's army count |
| `timestep` | scalar | Current game step |
| `allied_cells` | `(H,W)` | Mask of teammates' visible cells (team games; all-False otherwise) |
| `allied_land_count` | scalar | Teammates' cell count |
| `allied_army_count` | scalar | Teammates' army count |

`obs.as_tensor()` stacks the first 14 fields into a `(14, H, W)` tensor;
`obs.as_tensor(include_allied=True)` appends the three allied channels.

### Action

Actions are arrays of 5 integers: `[pass, row, col, direction, split]`

| Index | Field | Values |
|-------|-------|--------|
| 0 | `pass` | `1` to pass, `0` to move |
| 1 | `row` | Source cell row |
| 2 | `col` | Source cell column |
| 3 | `direction` | `0`=up, `1`=down, `2`=left, `3`=right |
| 4 | `split` | `1` to send half army, `0` to send all-1 |

When castle building is enabled, `[2, row, col, 0, 0]` requests a build.
The default environment does not enable building.

Use `compute_valid_move_mask` to get legal moves:

```python
from generals import compute_valid_move_mask

mask = compute_valid_move_mask(obs.armies, obs.owned_cells, obs.mountains)
# mask shape: (H, W, 4) - True where move from (i,j) in direction d is valid
```

## Tools and examples

Run examples from the repository root:

```bash
python examples/simple_example.py
python examples/multiplayer_example.py
python examples/visualization_example.py
```

The last command opens a desktop GUI. The Coworld browser client is maintained
in [`integrations/softmax/static/`](../integrations/softmax/static).

[`competition/matchup.py`](../competition/matchup.py) runs two stdio agents.
Its `--mode competition` flag and `make match` select the research preset above.
Reference agents in Python, C++, and Rust live under
[`competition/agents/`](../competition/agents); their wire format is defined in
[`competition/protocol.py`](../competition/protocol.py).

[`remote.autopilot`](remote/generalsio_client.py) and
[`examples/client_example.py`](../examples/client_example.py) are external-server
research tools. They do not launch a Softmax game or implement its hosted player bridge.

See [experimental training examples](../examples/_experimental/README.md),
[throughput measurements](../paper/benchmarks/README.md), and
[replay/reference validation](../paper/validation/README.md) for research workflows
and the scope of their evidence.

## Citation

```bibtex
@misc{generals_rl,
      author    = {Matej Straka, Martin Schmid},
      title     = {Artificial Generals Intelligence: Mastering Generals.io with Reinforcement Learning},
      year      = {2025},
      eprint    = {2507.06825},
      archivePrefix = {arXiv},
      primaryClass = {cs.LG},
}
```
