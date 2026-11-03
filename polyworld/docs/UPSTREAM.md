# Sources

This is a local Nim implementation of the basic Generals rules. It follows
the separation of simulation, bots, input, and Silky rendering used by
`Metta-AI/coworld-galcon`. No Galcon game code or GPL graphics are copied.

The rules and classic board presentation were consulted in
`Metta-AI/coworld-generals-io`, the `generals-competition` implementation
derived from `strakam/generals-bots`.

The crown, city, and mountain PNGs in `assets/images` are copied from
`generals/assets/images` in that repository. They retain the MIT notice
for Matej Straka in `assets/licenses/generals-MIT.txt`. Quicksand retains
its separate OFL notice in `assets/fonts/OFL-Quicksand.txt`.

The unmodified question-mark mountain icon in `assets/images/obstacle.png`
was downloaded from [generals.io](https://generals.io/obstacle.png) on
2026-11-02. It represents both mountains and cities hidden by fog, matching
the reference's shared unknown-obstacle visibility rule.

The leaderboard, half-turn counter, local chat panel, and continuous fog
follow the original site's presentation. Quicksand Regular and Bold were
downloaded unchanged from `https://generals.io/Quicksand-Regular.ttf` and
`https://generals.io/Quicksand-Bold.ttf`. Their embedded 2019 copyright notice
is retained with the SIL Open Font License in `assets/fonts/OFL-Quicksand.txt`.
Player labels use engine-supplied names, BASIC filenames, or `Player N`.
Star ranks show supplied MMR values and display as unknown when omitted.
The game does not fetch online accounts or rankings.
The replay eye icons in `assets/images/eye.svg` and `eye-dark.svg` were
retrieved unchanged from the original site's public assets. Checkboxes
combine selected players' fog, and eye buttons select map orientation.

Queued-move arrows follow the site's white Unicode glyphs, dark outline,
and placement near the outgoing edge of each source tile. Quicksand lacks
these glyphs, so they use the site's named Liberation Sans fallback.
The unmodified Liberation Sans Regular font comes from the official
[Liberation Fonts 2.1.5 release](https://github.com/liberationfonts/liberation-fonts/releases/tag/2.1.5).
Its copyright and SIL Open Font License are retained in
`assets/fonts/OFL-LiberationSans.txt`.

The unmodified default button, window, and widget PNGs in `assets/tractor`
come from `Metta-AI/polyworld_art/themes/main`. The small shared UI images
come from its `ui` directory. The source artwork revision is
`93a704a7bdaaba04727ef1be0d06422c61952312`. These project-generated images
retain the CC0 terms in `assets/licenses/polyworld-art-CC0.txt`.
Replay controls in `assets/transport` come unchanged from the same
revision's `icons` directory and retain its `LICENSE.art`. The viewer uses
Polyworld's shared player and transport layout, following Galcon's
fixed-board integration. Replay files use the shared action tape, as in
Gods of the Arena.

Rubik and Overpass Mono are from `polyworld_art/fonts`. Their OFL notices
are included beside the fonts. The game theme uses Quicksand for its UI,
with light square panels and teal offset shadows. Teal buttons use black
offset shadows.
The retained Tractor artwork and Rubik fonts are not loaded by this theme.

BASIC policies use Bassy and the shared Polyworld policy host and mailbox
modules. Player name fallback follows GotA's public roster conventions.
The pinned Nim dependency revisions are in `dependencies.lock`.

# Scope

This is a standalone local game with a human player and scripted opponents.
It has no accounts, hosted matches, WebSocket protocol, or external service.
It does not reproduce all current competition variants or the live
generals.io service. Classic movement, production, fog, move resolution,
general capture, and mutual general trades follow the pinned Python engine.
Maps use deterministic local generation with classic spacing, reachable
generals, neutral city garrisons, and player-count-dependent dimensions.
FFA matches accept every player count from 2 through 10. Generated layouts
need not match the original game's random maps. See `docs/MAPS.md` for the
generation contract. Castle construction, teams, server timeouts, and
surrender events are outside this local ruleset.

The test-only reference files under `tests/reference/upstream` are unchanged
MIT source from revision `43deb578ccaee91fce317169691a0d8a0206a01e` of
`Metta-AI/coworld-generals-io`. They are not included in the native app or its
assets. `docs/REFERENCE.md` describes the comparison and its limitations.
