import common, profiles, worlds

type Observation* = object
  visible*: seq[bool]
  kinds*, owners*, armies*: seq[int]
  myLand*, myArmy*, oppLand*, oppArmy*: int

proc visibility*(
    world: World,
    player: int,
    visible: var seq[bool]
) {.measure.} =
  ## Reuses a fog buffer while revealing owned cells and their neighbors.
  visible.setLen(world.tiles.len)
  for value in visible.mitems:
    value = false
  if player < 0 or player >= world.config.players:
    return
  for i, tile in world.tiles:
    if tile.owner != player:
      continue
    let
      x = i mod world.config.width
      y = i div world.config.width
    for dy in -1 .. 1:
      for dx in -1 .. 1:
        let neighbor = world.index(x + dx, y + dy)
        if neighbor >= 0:
          visible[neighbor] = true

proc visibility*(world: World, player: int): seq[bool] =
  ## Allocates a fog mask for callers that do not retain a reusable buffer.
  world.visibility(player, result)

proc observed*(world: World, player: int): Observation =
  ## Produces reference FFA fog masks, hidden armies, and public totals.
  result.visible = world.visibility(player)
  result.kinds = newSeq[int](world.tiles.len)
  result.owners = newSeq[int](world.tiles.len)
  result.armies = newSeq[int](world.tiles.len)
  for i, tile in world.tiles:
    if result.visible[i]:
      result.kinds[i] = tile.kind.ord
      result.owners[i] = tile.owner
      result.armies[i] = tile.army
    else:
      result.kinds[i] = if tile.kind in {Mountain, City}: -2 else: -1
      result.owners[i] = -1
    if tile.owner == player:
      inc result.myLand
      result.myArmy += tile.army
    elif tile.owner >= 0:
      inc result.oppLand
      result.oppArmy += tile.army
