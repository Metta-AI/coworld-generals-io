# Generals roadmap

Updated November 2, 2026 against the repository implementation.
See [the adapter guide](README.md) for code ownership and commands,
[VARIANTS.md](VARIANTS.md) for release/league records, and
[MIGRATION.md](MIGRATION.md) for reference comparisons and provenance.
Source changes on `main` and the last published Coworld are separate states.
The latest recorded hosted release is [0.6.2](VARIANTS.md#062--october-31-2026-utc).

## Implemented

- **Three modes:** classic 1v1, FFA with three through eight seats, and
  build-your-own-castles 1v1. Each has paced human variants.
- **Polyworld hosted engine:** imported Nim simulation alongside the retained JAX
  runtime; Compose and uploaded manifests select Polyworld. See [integration](POLYWORLD.md).
- **FFA maps and outcomes:** Polyworld player-count-dependent sampling, Survival
  placements, kill credit, surrender capture windows, inactivity, and idle/long-game adjudication.
- **Player runtimes:** BASIC files run in bounded game-owned workers;
  container players and humans use authenticated WebSockets. The manifest
  declares both `platform-hosted` and `game-hosted` runtimes.
- **Shared browser client:** local/hosted controls, public live scores,
  full-map/player replay perspectives, seeking, gzip import, and download.
  Completed recordings reach connected browsers before the hosted proxy retires.
- **Packaging:** generated manifest, separate game/player images, static replay
  bundle, and a pinned-SDK release workflow with native and hosted certification.
- **Recorded hosted proof:** variable-size FFA, Survival league results,
  live-to-replay handoff, and mixed runtimes have release evidence in VARIANTS.md.
  The recorded FFA entry point is [softmax.com/generals](https://softmax.com/generals).

## Remaining boundaries

- **Official-engine coverage:** map sampling and selected move/outcome methods
  have comparison evidence. Full live-engine, fog, event, and castle-building
  certification remain incomplete. Keep privately supplied reference sources
  outside this repository and distributed artifacts.
- **External generals.io handoff:** `generals/remote` is a research client.
  Official lobby/authentication handoff, seat identity, cancellation, reconnect,
  and completion callbacks need an agreed integration contract.
- **Rating parity:** the recorded FFA league uses OpenSkill Plackett-Luce;
  exact official star parameters remain unavailable. Accelerated bot execution
  and hosted job deadlines differ from the official live game.
- **Participant work:** Hunter's earlier classic submission is recorded in
  [HUNTER.md](HUNTER.md). Re-check its membership and scheduled results before
  continuing that exercise. It does not establish present leaderboard strength.

## Maintenance

Changes to rules, protocols, browser assets, dependencies, or player execution
need affected engine/system/browser checks and a certified Coworld release.
Embedded README/protocol edits also require manifest regeneration. A docs commit
and source CI do not update the deployed game's embedded documentation.

Retain release inputs, artifact identities, and hosted evidence in VARIANTS.md
and MIGRATION.md. Keep personal access troubleshooting and task logs out of Git.
The [September roadmap](https://github.com/Metta-AI/coworld-generals-io/blob/4b76197/integrations/softmax/ROADMAP.md)
is historical context; its v0.3.3 limits and unfinished FFA/browser tasks are superseded.
