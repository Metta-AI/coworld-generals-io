# Generals modes and leagues

The game is displayed as **generals.io**. One `generals-competition` Coworld
carries every mode; each bot mode runs as its own Softmax league. The display-name
override preserves the manifest identity, version history, and existing links.
New releases are maintained in `Metta-AI/coworld-generals-io`.

## Modes

| Variant | Seats | Rules | Turn cap |
| --- | --- | --- | --- |
| `competition` | 2 | Classic rules, neutral castles | 2,000 |
| `ffa` | 4 | Ranked FFA maps, Survival outcomes and official adjudication | 50,002 |
| `ffa-3`, `ffa-5` through `ffa-8` | 3, 5–8 | Corresponding ranked-size FFA | 50,002 |
| `castles` | 2 | Build castles on owned plain land; no starting neutral castles | 2,000 |
| `human`, `ffa-human`, `castles-human` | 2, 4, 2 | Corresponding rules, 500 ms minimum tick and 1 s deadline | 1,200 |
| `ffa-3-human`, `ffa-5-human` through `ffa-8-human` | 3, 5–8 | Corresponding paced FFA | 1,200 |

Human variants keep 1,200 turns: at two turns per second, 2,000 turns would take
at least 17 minutes and risk Softmax's 20-minute hosted episode deadline. Every
mode disables Deathtouch and resolves moves in generals.io's order (see README).
FFA uses Survival ordering: a kill or win qualifies a player for the upper
partition, then each partition sorts by reverse elimination order. Caps
adjudicate remaining players by army, land, and seat rather than drawing.
The official long-game threshold completes engine tick 50,002. Two engine
ticks correspond to one full official game turn. Softmax's accelerated bot
clock, finite job deadline, and unverified exact star parameters remain differences.
See README and the player protocol for surrender, inactivity, and scoring.

## Leagues

| League | Variant | League ID | Division |
| --- | --- | --- | --- |
| [Classic 1v1](https://softmax.com/observatory/v2?detail=league:league_8c189954-be68-479c-a092-eeb79c436d12) | `competition` | `league_8c189954-be68-479c-a092-eeb79c436d12` | Competition `div_5ee4b276-f330-42e8-b8e4-a6097c779d99` |
| [FFA (3–8 players)](https://softmax.com/observatory/v2?detail=league:league_f189ad01-2700-4fc8-ba89-f9de477099e4) | `ffa`, `ffa-3`, `ffa-5` through `ffa-8` | `league_f189ad01-2700-4fc8-ba89-f9de477099e4` | FFA `div_ac86d8a0-7b43-41bb-b6e7-1867f7b47d08` |
| [Build 1v1](https://softmax.com/observatory/v2?detail=league:league_b371d42e-bed5-4f33-ac02-fca229860ddf) | `castles` | `league_b371d42e-bed5-4f33-ac02-fca229860ddf` | Castles `div_ede858f5-6c57-4d03-b16d-a843a35e8bc2` |

All three are public and use the platform commissioner. FFA uses OpenSkill
Plackett-Luce (mu 50, sigma 50/3); Classic and Build retain Elo. All follow the
canonical Coworld version: a certified upload moves every league to it without
league changes. Classic and Build use Swiss-neighbor scheduling.

FFA uses `scaling_roster`, with seat rungs `[3, 4, 5, 6, 7, 8]`, eight episodes
per round, `insufficient_players: do_not_run`, and `roster_overflow: partition`.
`variant_rotation_by_seat_count` maps four seats to `ffa` and each other count
to `ffa-N`. This seats the current roster without cloning entrants and partitions
rosters above eight into separate tables. Publish the new variants before
applying this scheduler configuration. Preserve the other stored league settings
using a conditional replacement from `/settings/snapshot`.

The FFA and Build leagues were created on September 17 (20:24 UTC) by the
Softmax team, after Matej's account was refused with HTTP 403
`Only Softmax team members may set the default variant`. Matej owns the classic
league; setting a league's default variant remains team-only.

## Validation and maintenance

The same engine, server, player bridge and replay renderer implement all modes.
New rules or visuals require one Coworld build; league scheduler configuration
is managed separately. Add focused checks when changing elimination, fog,
build receipts, player counts, or browser queues. Certify the container and run
hosted verification for each affected mode; classic-only certification does not
prove FFA or building works.

Local smoke/full matches (omit `--max-turns` for the hosted mode budget):

```bash
python -m integrations.softmax.local --variant ffa --seed 7
python -m integrations.softmax.local --variant castles --seed 7
GENERALS_BROWSER_TESTS=1 pytest tests -q
```

These baseline matches validate integration, not playing strength or draw-rate
balance. Release 0.4.0 shields WebSocket cleanup from cancellation. Release 0.4.2
drains terminal messages before shutting down the game server.

## Releases

Ignored deployment logs, manifests, replay artifacts and exact API responses are
kept in `local-output/release-<version>/`.

### 0.6.0 — October 30, 2026 (UTC)

- Released source `66050e3c2239ff14189186ed254af6c1aefc9f8e` using Coworld SDK
  0.1.60. [Release workflow](https://github.com/Metta-AI/coworld-generals-io/actions/runs/41127614548)
  passed all eight native AMD64 fixtures and all ten hosted certification checks.
- Canonical Coworld: `cow_adf51684-c097-4f0c-ba02-c1d8e138b61b`. All three
  leagues resolve to it. FFA remains the game's public default, with three-to-eight
  seats and eight episodes per round.
- FFA now uses official Survival ordering, kill credit, the 50-tick surrender
  capture window, initial inactivity rules, and idle/long-game adjudication.
  Ordinary bot FFA permits tick 50,002; human variants retain their hosted budget.
  The viewer displays two engine ticks per full official turn.
- The existing FFA league migrated from Elo to OpenSkill Plackett-Luce, with
  initial mu 50 and sigma 50/3. Its four entrants, round history, episode results,
  score tallies and round counts were preserved. Elo's pairwise win/draw/loss
  counters restarted because OpenSkill counts whole episodes. Scheduling was
  paused only during the validated commissioner-state/settings migration.
  Round 4610 (`round_f0188358-99ae-41ce-b3c9-bfe38a6b2905`) then completed
  eight games under the preceding game version: every skill estimate updated,
  uncertainty shrank, and historical round counts advanced normally.
- [Source CI](https://github.com/Metta-AI/coworld-generals-io/actions/runs/41127075348)
  passed 223 checks with one private reference skipped. All 224 checks passed
  locally, including the identical terminal-board reference. Scoped Ruff,
  JavaScript syntax, manifest consistency and diff checks passed.
- Against the supplied live Game methods, all 600 generated Survival cases and
  all 600 surrender/neutralization cases matched across three through eight
  players. These are method comparisons, not full live rated-game validation.
- Eight real local bots completed 50,002 ticks with zero timeouts. The recording
  is 31,224,836 bytes raw and 1,529,805 bytes gzip. The retained system workflows
  cover play beyond 2,000 ticks, idle adjudication, capture during surrender,
  exact neutralization timing, Survival ordering and browser replay seeking.
- Manual browser proof covers 1440×1000 and 390×844 long replay views, seeking
  from tick 49,000 back to 512, fog, scorecards and the official counter.
  A real human FFA lobby at 1440×1200 verifies Surrender after automatic passes.
  [Desktop](https://softmax.nexus/artifacts/f7cd7be7-868d-480c-a151-dffed2b34e7a),
  [mobile](https://softmax.nexus/artifacts/dc479421-1397-442d-8657-de3b608d0109),
  [seeking recording](https://softmax.nexus/artifacts/202ea31c-ff6a-48da-acea-a5915ce9f75b),
  [surrender recording](https://softmax.nexus/artifacts/9366e77d-5ac1-47ac-9d36-9c041473f6b6).
- Public wiki rules now describe Survival, exits, inactivity, timing and OpenSkill.
  Exact official star parameters, accelerated bot execution and hosted deadlines
  remain differences; the release does not claim exact star-rating parity.

Hosted verification:

- Ordinary eight-seat request `xreq_6daee53b-7f81-41bf-ae34-28400c853b8b`
  completed all 50,002 ticks with zero timeouts and a 37,028,185-byte recording.
  [Public episode](https://softmax.com/generals/episodes/a9aa3f7d-089c-461b-bc1a-68631ea1ef8c).
- Round 4611 (`round_c605f9af-da26-4e68-a232-bdd8811680e1`) completed all eight
  ordinary four-player games on 0.6.0 and updated the same league's OpenSkill
  standings. Its scores distinguish every Survival placement. One checked game
  completed at tick 853 with zero timeouts and placements `[4, 1, 2, 3]`.
  [League episode](https://softmax.com/generals/episodes/c3bb4623-5ac5-4619-b14c-13ee4f4857ed).
- The hosted live spectator reached tick 50,002, but its query-based recording
  opt-in was lost through Kubernetes proxying. Saved public replays load correctly.
  Release 0.6.1 replaces the query opt-in with a WebSocket subscription.

Published artifact identities:

- Manifest: `sha256:332b08f2ad85a58302d9b8bfffb7ae0aad124e23a49a111716f6bec15ca78e23`.
- Game image: `sha256:5c868067edf7be25d83d4e449315b1f16e61cc865ba7cbfb7c870c094236fa7a`.
- Player image: `sha256:f4a9a936436febd8886a5687e859d3ee38245ccc40e68314d1f5c400174d7c43`.
- Replay bundle: `sha256:517da0eac26ad3603739a584a8e14b740a843527716092ddfabd1867e8f142ec`.

### 0.5.0 — October 30, 2026 (UTC)

- Released from `00f6cf90f47ff388c245b36ea782a96585d985b2` with Coworld SDK
  0.1.60. [Release workflow](https://github.com/Metta-AI/coworld-generals-io/actions/runs/41116286701)
  passed all ten container checks separately for classic, each FFA size from
  three through eight, and castle-building. Hosted certification passed all ten.
- Canonical Coworld: `cow_48f4d81a-2fa5-4db2-a72e-ed50c0648b3f`.
  All three leagues follow it. FFA is the game's default league and is displayed
  as **FFA (3–8 players)**. Its stored scheduler is the `scaling_roster`
  configuration above; the current four entrants play four-seat episodes.
- Source CI passed 221 tests, with the private-reference check skipped.
  All 222 checks passed locally, including that check, using separate module
  invocations. The official map comparison matched all 600 cases.
- Full-length eight-seat verification request
  `xreq_697778af-acd8-4eac-9634-9e5cd38bb519` completed 2,000 turns on a
  26×25 board with zero timeouts. The baseline bots drew at the turn cap.
  [Public episode](https://softmax.com/generals/episodes/204000b2-594c-422d-82ca-e6504abfbe8c).
- Public replay verification covered eight scorecards, colors, perspectives,
  seeking, fullscreen, and 1440×1000 / 390×844 viewports. Public wiki rules were
  updated while preserving its existing public upstream source links.

Published artifact identities:

- Manifest: `sha256:deef8c8222c0a41a124358bd49283f0fa764d83f2fc6070cb14852ad69654f95`.
- Game image: `sha256:cdf332ca17c59462f11708e4ae98ec7575959abe63b5cf88e31bd2e2da88fdd6`.
- Player image: `sha256:6e1c0aec94017fb4ba7e8d23743e227750c3cb4b4a179f56796e2a06473b6604`.
- Replay bundle: `sha256:b2f38687adf05c23ab48c9bd02ff257925c226a2b2abd65a239e84e248e00d80`.

### 0.4.2 — October 30, 2026 (UTC)

- Rebuilt native AMD64 from `2d6d9ccdd8f67932dcf2d5b847a710e08cdb3453`
  using Coworld SDK 0.1.60. This includes the completion handoff and full-height
  replay layout. The source suite passed 220 tests, with one private-reference
  check skipped.
- [Release workflow](https://github.com/Metta-AI/coworld-generals-io/actions/runs/40980596045)
  passed ten container certification checks separately for classic, FFA, and
  castle-building, then uploaded and passed hosted certification.
- Coworld `cow_20f616ae-1c0e-4bb5-9dc3-b2ac495a9d94` is canonical. All three
  leagues resolve both their current and canonical game to this version.
- The displayed name is now `generals.io`, set through the game's persistent
  display-name override. It remains set after canonical promotion.
- Full-length hosted verification requests, using the existing Expander and
  Builder policies with the ordinary 2,000-turn variants:
  classic `xreq_99f9eb5e-f810-4d18-b121-ebc87a174c0d`,
  FFA `xreq_87ef68d2-648d-4091-bb40-676b82fc7edf`,
  castles `xreq_b3b5f437-f458-464b-842f-79dc9b2b9db9`.

Published artifact identities:

- Manifest: `sha256:e15438ac084168328bf87f53474ac57f9e84ebba0462412261b81a771c36d100`.
- Game image: `img_3285aced-b80c-4c10-952e-0e6b33cf8e34`.
- Player image: `img_2f64f485-4bca-4935-a666-0c9c06143684`.
- Replay bundle: `sha256:f7a67556ab61c57a0ea8a3c228768e28d608b9d49d8a19dfd886bf3a8a843ef9`.

### 0.3.3 — September 27, 2026

- Documentation only: the embedded README states per-mode turn caps, the
  generals.io move order and the three leagues. Release source `f65fb55`.
- Coworld `cow_8f61ead9-f3c6-4be0-95ed-7ad0de6c961e`, canonical; all three leagues
  moved to it. Local and hosted certification passed. The live wiki was updated
  from `WIKI.md` the same day.

### 0.3.2 — September 27, 2026

- FFA and castle-building bot variants raised to 2,000 turns; human variants
  stay at 1,200. Release source `04e76ba` on `softmax`.
- Coworld `cow_08589716-ac45-4575-b3de-7e4cab635fc8`; all three leagues moved
  to it. Hosted certification passed ten checks and five smoke episodes.
- Full 2,000-turn FFA and castles games passed locally, in container
  certification and hosted (69 s and 49 s), all with zero timeouts:
  [FFA](https://softmax.com/generals-competition?e=78143037-11fc-4c4c-b6ca-2c62dbd90712),
  [castles](https://softmax.com/generals-competition?e=4a5bd1d4-8638-402b-91b8-228ecff085c9).

### 0.3.1 — September 27, 2026

- Master's replay-verified generals.io rules and faster simulator merged into
  `softmax` (`46c48c4`); general trade stays off, as in master's default env.
- Richard's PR #141 merged (`2f731fe`): classic bot games to 2,000 turns, replay
  viewer up to 2,001 frames. Release source `555622d`.
- Coworld `cow_cc72cd7d-5c39-469e-bae2-d79ecb8aebd3`. 207 tests plus 7 Chromium
  checks passed; local and hosted certification passed. Hosted full-length games
  in every mode completed with zero timeouts:
  [classic, 2,000 turns](https://softmax.com/generals-competition?e=5962de96-e834-48b4-9677-1d20db5722d1),
  [FFA](https://softmax.com/generals-competition?e=b657da12-19be-4bfe-bb59-dca60368d9f7),
  [castles](https://softmax.com/generals-competition?e=0368e1e7-ca3e-455c-8aec-574833f3a9e5).

### 0.3.0 — September 17, 2026

- Added `ffa`, `castles` and their human variants. Coworld
  `cow_8c336ec5-413c-4cfc-99b5-fbe2c1f71b5d`; release source `7632640` on
  `softmax` (implementation `3af20af`).
- 188 tests passed, including real Chromium checks. All three local container
  certification fixtures passed their ten checks. Hosted certification passed
  ten checks and five classic smoke episodes.
- Two full-length hosted episodes per new mode completed at turn 1,200 with
  zero timeouts and valid results/replays; building episodes contained eight
  and five construction actions. Requests: FFA
  `xreq_18150375-c866-4f82-a766-cc7a885bd79a`, castles
  `xreq_2d7c9001-a5cc-46a1-bb5d-ab2dbf817014`. Website replays:
  [FFA](https://softmax.com/generals-competition?e=ca3ebdc5-b9e5-413e-8169-7df02c54f692),
  [castles](https://softmax.com/generals-competition?e=933f9bbf-9338-4f9f-b00d-4a0d7d574079).

Hosted verification uses the baselines `strakam-generals-expander:v2`
(`c2c6eb89-51ff-4fba-928d-e35dfa278357`) and `strakam-generals-builder:v1`
(`0d7a26da-c81a-4173-906e-ee1fff21ffc4`), registered for 0.3.0 on the uploaded
lightweight player image. They are not league entrants.
