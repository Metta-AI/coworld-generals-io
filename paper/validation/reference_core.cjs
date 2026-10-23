// Private engine adapter. Engine sources are supplied externally, never bundled.
'use strict';

const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const engineDir = path.resolve(process.argv[2]);
const replay = JSON.parse(fs.readFileSync(0, 'utf8'));
const sources = {};
for (const name of ['Constants.js', 'Map.js', 'MoveResolver.js', 'ReplaySimulationCore.js']) {
  sources[name] = createHash('sha256').update(fs.readFileSync(path.join(engineDir, name))).digest('hex');
}
const ReplaySimulationCore = require(path.join(engineDir, 'ReplaySimulationCore.js'));
const game = new ReplaySimulationCore(replay);
// Do not extend a truncated recording until the all-AFK timeout invents a winner.
const lastEvent = Math.max(0, ...replay.moves.map(move => move.turn), ...replay.afks.map(afk => afk.turn));
assert.ok(lastEvent < 100000, 'Replay exceeds the 100000-turn validation limit');
const owners = [Array.from(game.map._map)];
const armies = [Array.from(game.map._armies)];
while (!game.isOver() && game.turn <= lastEvent) {
  const previousTurn = game.turn;
  game.nextTurn();
  assert.equal(game.turn, previousTurn + 1, 'Reference core did not advance exactly one turn');
  owners.push(Array.from(game.map._map));
  armies.push(Array.from(game.map._armies));
}
assert.ok(game.isOver(), 'No terminal outcome within the recorded move/AFK timeline');
assert.equal(game.currentMoveIndex, replay.moves.length, 'Game ended before consuming all recorded moves');
process.stdout.write(JSON.stringify({
  W: replay.mapWidth,
  H: replay.mapHeight,
  turns: game.turn,
  winner: game.isOver().map(socket => socket._replayIndex),
  consumed: game.currentMoveIndex,
  n_moves: replay.moves.length,
  owners,
  armies,
  reference_sources_sha256: sources,
}));
