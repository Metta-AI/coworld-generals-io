import
  std/os,
  chroma, pixie, silky, vmath,
  common

const
  ArrowCanvas* = 32
  Glyphs = ["←", "→", "↑", "↓"]

type ArrowDirection* = enum
  LeftArrow, RightArrow, UpArrow, DownArrow

proc arrowName*(size: int, direction: ArrowDirection): string {.raises: [].} =
  ## Names one direction and font size in the shared image atlas.
  "arrow-" & $size & "-" & $direction

proc addArrows*(builder: AtlasBuilder, assets: string) =
  ## Rasterizes the site's white arrow glyphs with a faint black outline.
  let font = newFont(readTypeface(assets / "fonts/LiberationSans-Regular.ttf"))
  for size in 10 .. 17:
    font.size = size.float32
    for direction in ArrowDirection:
      let
        image = newImage(ArrowCanvas, ArrowCanvas)
        arrangement = font.typeset(
          Glyphs[direction.ord],
          vec2(ArrowCanvas),
          CenterAlign,
          MiddleAlign
        )
      font.paint.color = color(0, 0, 0, 0.4)
      image.strokeText(arrangement, strokeWidth = 2)
      font.paint.color = color(1, 1, 1, 1)
      image.fillText(arrangement)
      let name = arrowName(size, direction)
      if not builder.addImage(name, image):
        raise newException(GeneralsError, "Cannot fit arrow glyph: " & name)
