import common, visions

type Pov* = object
  selected*: array[MaxPlayers, bool]
  orientation*: int
  origins*: array[MaxPlayers, int]

proc newPov*(world: World): Pov {.raises: [].} =
  ## Saves initial homes while starting with an unobstructed replay view.
  result.orientation = -1
  for player in 0 ..< MaxPlayers:
    result.origins[player] =
      if player < world.config.players and player < world.generals.len:
        world.generals[player]
      else:
        -1

proc togglePlayer*(pov: var Pov, world: World, player: int) {.raises: [].} =
  ## Toggles fog for a living player with land, ignoring unavailable seats.
  if player < 0 or player >= MaxPlayers or
    player >= world.config.players or player >= world.alive.len or
    not world.alive[player]:
      return
  for tile in world.tiles:
    if tile.owner == player:
      pov.selected[player] = not pov.selected[player]
      return

proc toggleOrientation*(pov: var Pov, player: int) {.raises: [].} =
  ## Selects one original home orientation independently of fog selection.
  if player < 0 or player >= MaxPlayers or pov.origins[player] < 0:
    return
  pov.orientation =
    if pov.orientation == player:
      -1
    else:
      player

proc coordinates*(
    pov: Pov,
    config: Config,
    index: int
): tuple[x, y: int] {.raises: [].} =
  ## Mirrors map coordinates so the chosen original home stays upper left.
  if config.width <= 0 or config.height <= 0 or index < 0 or
    index div config.width >= config.height:
      return (-1, -1)
  result = (index mod config.width, index div config.width)
  if pov.orientation < 0 or pov.orientation >= MaxPlayers:
    return
  let origin = pov.origins[pov.orientation]
  if origin < 0 or origin div config.width >= config.height:
    return
  if origin mod config.width >= (config.width + 1) div 2:
    result.x = config.width - 1 - result.x
  if origin div config.width >= (config.height + 1) div 2:
    result.y = config.height - 1 - result.y

proc updateVisibility*(
    pov: var Pov,
    world: World,
    visible: var seq[bool],
    scratch: var seq[bool]
) =
  ## Unions selected living views, revealing the full map when none remain.
  var
    hasLand: array[MaxPlayers, bool]
    anySelected = false
  for tile in world.tiles:
    if tile.owner >= 0 and tile.owner < MaxPlayers:
      hasLand[tile.owner] = true
  for player in 0 ..< MaxPlayers:
    if player >= world.config.players or player >= world.alive.len or
      not world.alive[player] or not hasLand[player]:
        pov.selected[player] = false
    anySelected = anySelected or pov.selected[player]
  visible.setLen(world.tiles.len)
  for shown in visible.mitems:
    shown = not anySelected
  if not anySelected:
    return
  for player in 0 ..< MaxPlayers:
    if not pov.selected[player]:
      continue
    world.visibility(player, scratch)
    for i in 0 ..< visible.len:
      visible[i] = visible[i] or scratch[i]
