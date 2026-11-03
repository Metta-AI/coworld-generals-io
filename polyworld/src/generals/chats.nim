import
  std/unicode,
  common, events

type Editor* = object
  text*: seq[Rune]
  cursor*, anchor*: int
  focused*: bool

proc selection*(editor: Editor): tuple[first, last: int] {.raises: [].} =
  ## Returns the selected half-open range, clipped to the current text.
  let
    cursor = clamp(editor.cursor, 0, editor.text.len)
    anchor = clamp(editor.anchor, 0, editor.text.len)
  (min(cursor, anchor), max(cursor, anchor))

proc normalize(editor: var Editor) {.raises: [].} =
  ## Keeps editing positions inside the explicitly bounded rune array.
  assert editor.text.len <= MaxChatCharacters
  editor.cursor = clamp(editor.cursor, 0, editor.text.len)
  editor.anchor = clamp(editor.anchor, 0, editor.text.len)

proc value*(editor: Editor): string {.raises: [].} =
  ## Encodes the editor's text without splitting Unicode characters.
  for rune in editor.text:
    result.add(rune.toUTF8())

proc selectedText*(editor: Editor): string {.raises: [].} =
  ## Returns the current selection for local clipboard operations.
  let selected = editor.selection()
  for i in selected.first ..< selected.last:
    result.add(editor.text[i].toUTF8())

proc clear*(editor: var Editor) {.raises: [].} =
  ## Clears the draft and selection while preserving its focus state.
  editor.text.setLen(0)
  editor.cursor = 0
  editor.anchor = 0

proc erase(editor: var Editor, first, last: int) {.raises: [].} =
  ## Removes an existing half-open range and collapses the selection.
  assert first >= 0 and first <= last and last <= editor.text.len
  let count = last - first
  for i in last ..< editor.text.len:
    editor.text[i - count] = editor.text[i]
  editor.text.setLen(editor.text.len - count)
  editor.cursor = first
  editor.anchor = first

proc allowed(rune: Rune): bool {.raises: [GeneralsError].} =
  ## Validates Unicode scalars and rejects controls and line separators.
  let code = rune.int
  if code < 0 or code > 0x10ffff or code in 0xd800 .. 0xdfff:
    raise newException(GeneralsError, "Chat needs valid Unicode characters.")
  code >= 32 and code notin 127 .. 159 and
    code notin [0x2028, 0x2029]

proc insert*(editor: var Editor, text: string) {.raises: [GeneralsError].} =
  ## Replaces the selection with bounded, valid single-line text.
  if validateUtf8(text) != -1:
    raise newException(GeneralsError, "Chat text must contain valid UTF-8.")
  let
    selected = editor.selection()
    available = MaxChatCharacters -
      (editor.text.len - selected.last + selected.first)
  var
    accepted: seq[Rune]
    encodedBytes = 0
  for rune in text.runes:
    let acceptedRune = rune.allowed()
    encodedBytes += rune.toUTF8().len
    if acceptedRune and accepted.len < available:
      accepted.add(rune)
  if encodedBytes != text.len:
    raise newException(GeneralsError, "Chat text must use canonical UTF-8.")
  if accepted.len == 0:
    return
  editor.normalize()
  editor.erase(selected.first, selected.last)
  let previousLength = editor.text.len
  editor.text.setLen(previousLength + accepted.len)
  for i in countdown(previousLength - 1, editor.cursor):
    editor.text[i + accepted.len] = editor.text[i]
  for i, rune in accepted:
    editor.text[editor.cursor + i] = rune
  editor.cursor += accepted.len
  editor.anchor = editor.cursor

proc insert*(editor: var Editor, rune: Rune) {.raises: [GeneralsError].} =
  ## Inserts one printable Unicode scalar without exceeding the draft cap.
  if rune.allowed():
    editor.insert(rune.toUTF8())

proc backspace*(editor: var Editor) {.raises: [].} =
  ## Removes the selection or the character immediately before the cursor.
  editor.normalize()
  let selected = editor.selection()
  if selected.first != selected.last:
    editor.erase(selected.first, selected.last)
  elif editor.cursor > 0:
    editor.erase(editor.cursor - 1, editor.cursor)

proc deleteForward*(editor: var Editor) {.raises: [].} =
  ## Removes the selection or the character immediately after the cursor.
  editor.normalize()
  let selected = editor.selection()
  if selected.first != selected.last:
    editor.erase(selected.first, selected.last)
  elif editor.cursor < editor.text.len:
    editor.erase(editor.cursor, editor.cursor + 1)

proc moveCursor*(
    editor: var Editor,
    delta: int,
    extend = false
) {.raises: [].} =
  ## Moves by characters or collapses the selection toward the chosen side.
  editor.normalize()
  let selected = editor.selection()
  if not extend and selected.first != selected.last and delta != 0:
    editor.cursor = if delta < 0: selected.first else: selected.last
  elif delta > 0:
    editor.cursor += min(delta, editor.text.len - editor.cursor)
  else:
    editor.cursor += max(delta, -editor.cursor)
  if not extend:
    editor.anchor = editor.cursor

proc moveHome*(editor: var Editor, extend = false) {.raises: [].} =
  ## Moves to the start of the line, optionally extending the selection.
  editor.normalize()
  editor.cursor = 0
  if not extend:
    editor.anchor = editor.cursor

proc moveEnd*(editor: var Editor, extend = false) {.raises: [].} =
  ## Moves to the end of the line, optionally extending the selection.
  editor.normalize()
  editor.cursor = editor.text.len
  if not extend:
    editor.anchor = editor.cursor

proc selectAll*(editor: var Editor) {.raises: [].} =
  ## Selects the entire bounded chat draft.
  editor.normalize()
  editor.anchor = 0
  editor.cursor = editor.text.len
