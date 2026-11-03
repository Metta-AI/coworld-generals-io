import
  std/os,
  chroma, pixie, silky, vmath,
  polyworld/[player, gameuis, chrome],
  common

export player, gameuis

const
  ControlIcons = [
    "skip_to_start", "previous_frame", "play", "next_frame", "skip_to_end"
  ]
  SpeedIcons = ["speed_1x", "speed_2x", "speed_4x", "speed_16x"]
  GlyphColor = rgbx(226, 230, 239, 255)
  GlyphActive = rgbx(235, 216, 154, 255)

type Transport* = object
  player*: Player
  dragging*: bool

proc addTransport*(builder: AtlasBuilder, assets: string) =
  ## Adds the shared replay glyphs and ribbon without changing the game theme.
  proc add(name, directory: string) =
    ## Packs one replay image while preserving an existing atlas entry.
    if name in builder.atlas.entries:
      return
    let path = assets / directory / (name & ".png")
    try:
      if not builder.addImage(name, readImage(path)):
        raise newException(GeneralsError, "Cannot fit replay image: " & name)
    except IOError, OSError, PixieError:
      raise newException(
        GeneralsError,
        "Cannot load replay image " & path & ": " & getCurrentExceptionMsg()
      )
  for name in ControlIcons:
    add(name, "transport")
  for name in SpeedIcons:
    add(name, "transport")
  for name in ["pause", "loop"]:
    add(name, "transport")
  for name in ["frame.pureblack.9patch", "bartrack.9patch", "barfill.9patch"]:
    add(name, "tractor")

proc drawIcon(
    sk: Silky,
    panel: GameUiPanel,
    name: string,
    active = false
) =
  ## Centers the standard replay glyph inside its shared hit target.
  let
    entry = sk.atlas.entries[name]
    tint =
      if active:
        GlyphActive
      else:
        GlyphColor
  sk.drawQuad(
    panel.origin + vec2(8),
    vec2(48),
    vec2(entry.x.float32, entry.y.float32),
    vec2(entry.width.float32, entry.height.float32),
    tint
  )

proc drawTransport*(
    transport: var Transport,
    sk: Silky,
    window: Window,
    panel: GameUiPanel
) =
  ## Draws the shared playback controls and scrubber for a fixed game board.
  sk.drawRibbon(panel)
  let
    slots = panel.transportPanels()
    playing = transport.player.playing or transport.player.targetTick >= 0
    pressed = window.buttonPressed[MouseLeft]
  for i, slot in slots.controls:
    let name =
      if i == 2 and playing:
        "pause"
      else:
        ControlIcons[i]
    sk.drawIcon(slot, name)
    if pressed and slot.contains(sk.mousePos):
      case i
      of 0:
        transport.player.skipToStart()
      of 1:
        transport.player.stepBack()
      of 2:
        transport.player.togglePlay()
      of 3:
        transport.player.stepForward()
      of 4:
        transport.player.skipToEnd()
  sk.drawIcon(slots.loop, "loop", transport.player.repeating)
  if pressed and slots.loop.contains(sk.mousePos):
    transport.player.repeating = not transport.player.repeating
  for i, slot in slots.speeds:
    sk.drawIcon(slot, SpeedIcons[i], transport.player.speedIndex == i)
    if pressed and slot.contains(sk.mousePos):
      transport.player.setSpeed(i)
  let endTick = max(transport.player.timelineEnd, 1).float32
  sk.drawBar(
    slots.scrub.origin,
    slots.scrub.size,
    transport.player.tick.float32,
    endTick,
    rgbx(96, 132, 190, 255)
  )
  sk.drawBar(
    slots.recorded.origin,
    slots.recorded.size,
    transport.player.recordedTicks.float32,
    endTick,
    rgbx(151, 82, 199, 255)
  )
  if pressed:
    transport.dragging = slots.scrubHit.contains(sk.mousePos)
  if not window.buttonDown[MouseLeft]:
    transport.dragging = false
  if transport.dragging and slots.scrub.size.x > 0:
    let ratio = clamp(
      (sk.mousePos.x - slots.scrub.origin.x) / slots.scrub.size.x,
      0.0'f,
      1.0'f
    )
    transport.player.seekTo(
      int32(ratio * transport.player.timelineEnd.float32)
    )
  let caption = "Tick " & $transport.player.tick & " / " &
    $transport.player.timelineEnd
  discard sk.drawText(
    "Hud",
    caption,
    slots.tick.origin,
    GlyphColor,
    maxWidth = slots.tick.size.x,
    maxHeight = slots.tick.size.y,
    hAlign = RightAlign,
    vAlign = MiddleAlign
  )
