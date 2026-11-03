import common

const MaxQueuedMoves* = 64

type Controls* = object
  player*, selected*: int
  half*: bool
  moves*: seq[Move]

proc newControls*(general: int, player = 0): Controls =
  ## Selects one human seat's general, or disables spectator controls.
  Controls(
    player: player,
    selected: if player in 0 ..< MaxPlayers: general else: -1
  )

proc available(controls: Controls, world: World): bool =
  ## Reports whether the configured seat can issue live army orders.
  controls.player in 0 ..< MaxPlayers and
    controls.player < world.config.players and
    controls.player < world.generals.len and
    (world.alive.len == 0 or
      (controls.player < world.alive.len and world.alive[controls.player]))

proc home(controls: Controls, world: World): int =
  ## Returns the current owned general, or no selection for a stale home.
  if not controls.available(world):
    return -1
  let general = world.generals[controls.player]
  if general >= 0 and general < world.tiles.len and
    world.tiles[general].owner == controls.player:
      return general
  -1

proc clear*(controls: var Controls) =
  ## Cancels pending moves without changing the selected tile.
  controls.moves.setLen(0)

proc clear*(controls: var Controls, world: World) =
  ## Cancels a path and restores selection to currently owned land.
  if not controls.available(world):
    controls.selected = -1
    controls.clear()
    return
  let selected = controls.selected
  if selected < 0 or selected >= world.tiles.len or
    world.tiles[selected].owner != controls.player:
      controls.selected = controls.home(world)
      for move in controls.moves:
        if move.source >= 0 and move.source < world.tiles.len and
          world.tiles[move.source].owner == controls.player:
            controls.selected = move.source
  controls.clear()

proc select*(controls: var Controls, world: World, tile: int) =
  ## Selects owned land and cancels the previous movement path.
  if controls.available(world) and tile >= 0 and tile < world.tiles.len and
    world.tiles[tile].owner == controls.player:
      controls.clear()
      controls.selected = tile

proc enqueue*(
    controls: var Controls,
    world: World,
    target: int,
    half = false
): bool =
  ## Queues one cardinal step without inspecting hidden tile contents.
  let source = controls.selected
  if not controls.available(world) or world.config.width <= 0 or
    source < 0 or source >= world.tiles.len or
    target < 0 or target >= world.tiles.len or
    controls.moves.len >= MaxQueuedMoves:
      return false
  if controls.moves.len == 0 and world.tiles[source].owner != controls.player:
    return false
  let
    width = world.config.width
    distance = abs(source mod width - target mod width) +
      abs(source div width - target div width)
  if distance != 1:
    return false
  controls.moves.add Move(
    source: source,
    target: target,
    half: half or controls.half
  )
  controls.selected = target
  true

proc step*(
    controls: var Controls,
    world: World,
    dx, dy: int,
    half = false
): bool =
  ## Extends a queued path by one tile without wrapping at board edges.
  if not controls.available(world) or world.config.width <= 0 or
    controls.selected < 0 or controls.selected >= world.tiles.len:
      return false
  let
    x = controls.selected mod world.config.width + dx
    y = controls.selected div world.config.width + dy
  if x < 0 or x >= world.config.width or
    y < 0 or y >= world.config.height:
      return false
  controls.enqueue(world, y * world.config.width + x, half)

proc takeMove*(controls: var Controls): Move =
  ## Consumes one queued move or returns an explicit pass.
  if controls.player notin 0 ..< MaxPlayers:
    controls.clear()
    return noMove()
  if controls.moves.len == 0:
    return noMove()
  result = controls.moves[0]
  controls.moves.delete(0)

proc reconcile*(controls: var Controls, world: World, move: Move) =
  ## Stops a queued path when its last attack did not capture the next tile.
  if not controls.available(world):
    controls.selected = -1
    controls.clear()
    return
  if move.target < 0 or move.target >= world.tiles.len:
    return
  if world.tiles[move.target].owner != controls.player:
    controls.clear()
    controls.selected = move.source
  if controls.selected >= 0 and controls.selected < world.tiles.len and
    world.tiles[controls.selected].owner != controls.player and
    controls.moves.len == 0:
      controls.selected = controls.home(world)
