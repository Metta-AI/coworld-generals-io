# Coworld Generals.io

This repository owns the Softmax Generals game. Branch from `main`; retain the
upstream MIT license and attribution. Read `integrations/softmax/AGENTS.md`
and `integrations/softmax/MIGRATION.md` before changing the hosted game.

Fetch origin before work. Do not rewrite historical commits or remove published
releases: the former Nim game and its binary replays belong to their pinned releases.
The active Coworld remains `generals-competition`; repository renaming does not
rename its game, variants, leagues, or existing player protocols.

Write only end-to-end or system tests using real participating components.
Existing tests may run and remain coverage; do not add isolated or mocked tests.
Run the engine suite, manifest check, real browser flow, and container certification
before publishing. Record exact release inputs and results.

Keep the privately supplied official engine outside this public repository.
Do not publish it without its owner's explicit permission.
