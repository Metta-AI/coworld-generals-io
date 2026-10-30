# Generals modes and leagues

The game is displayed as **generals.io**. One `generals-competition` Coworld
carries every mode; each bot mode runs as its own Softmax league. The display-name
override preserves the manifest identity, version history, and existing links.
New releases are maintained in `Metta-AI/coworld-generals-io`.

## Modes

| Variant | Seats | Rules | Turn cap |
| --- | --- | --- | --- |
| `competition` | 2 | Classic rules, neutral castles | 2,000 |
| `ffa` | 4 | Ranked map generation, last surviving general wins | 2,000 |
| `ffa-3`, `ffa-5` through `ffa-8` | 3, 5–8 | Corresponding ranked-size FFA | 2,000 |
| `castles` | 2 | Build castles on owned plain land; no starting neutral castles | 2,000 |
| `human`, `ffa-human`, `castles-human` | 2, 4, 2 | Corresponding rules, 500 ms minimum tick and 1 s deadline | 1,200 |
| `ffa-3-human`, `ffa-5-human` through `ffa-8-human` | 3, 5–8 | Corresponding paced FFA | 1,200 |

Human variants keep 1,200 turns: at two turns per second, 2,000 turns would take
at least 17 minutes and risk Softmax's 20-minute hosted episode deadline. Every
mode disables Deathtouch and resolves moves in generals.io's order (see README).
FFA uses +1 for the winner, -1 for every other player, and all zeros at the turn
cap; it does not yet award intermediate finishing ranks. See README and the
player protocol for capture, timeout, building-cost, and fog rules.

## Leagues

| League | Variant | League ID | Division |
| --- | --- | --- | --- |
| [Classic 1v1](https://softmax.com/observatory/v2?detail=league:league_8c189954-be68-479c-a092-eeb79c436d12) | `competition` | `league_8c189954-be68-479c-a092-eeb79c436d12` | Competition `div_5ee4b276-f330-42e8-b8e4-a6097c779d99` |
| [FFA (3–8 players)](https://softmax.com/observatory/v2?detail=league:league_f189ad01-2700-4fc8-ba89-f9de477099e4) | `ffa`, `ffa-3`, `ffa-5` through `ffa-8` | `league_f189ad01-2700-4fc8-ba89-f9de477099e4` | FFA `div_ac86d8a0-7b43-41bb-b6e7-1867f7b47d08` |
| [Build 1v1](https://softmax.com/observatory/v2?detail=league:league_b371d42e-bed5-4f33-ac02-fca229860ddf) | `castles` | `league_b371d42e-bed5-4f33-ac02-fca229860ddf` | Castles `div_ede858f5-6c57-4d03-b16d-a843a35e8bc2` |

All three are public, use the platform commissioner with Elo ranking, and
follow the canonical Coworld version: a certified upload moves every league
to it without league changes. Classic and Build use Swiss-neighbor scheduling.

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

Local smoke/full matches (bot games default to the hosted 2,000-turn cap):

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
