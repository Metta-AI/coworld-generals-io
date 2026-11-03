import
  std/[strutils, unicode],
  generals/[chats, common, events]

echo "Testing bounded Unicode chat editing"

block:
  var editor: Editor
  editor.focused = true
  editor.insert("Hello ")
  editor.insert(Rune(0x1f642))
  doAssert editor.value() == "Hello 🙂"
  doAssert editor.text.len == 7
  editor.backspace()
  doAssert editor.value() == "Hello "
  editor.moveHome()
  editor.deleteForward()
  doAssert editor.value() == "ello "
  editor.moveEnd()
  editor.insert("world")
  editor.moveCursor(-5, extend = true)
  doAssert editor.selectedText() == "world"
  editor.insert("Nim")
  doAssert editor.value() == "ello Nim"
  doAssert editor.cursor == 8 and editor.anchor == 8
  editor.clear()
  doAssert editor.text.len == 0 and editor.cursor == 0
  doAssert editor.focused

block:
  var editor: Editor
  editor.insert("abcdef")
  editor.moveHome()
  editor.moveCursor(4, extend = true)
  doAssert editor.selection() == (0, 4)
  editor.moveCursor(-1)
  doAssert editor.cursor == 0 and editor.anchor == 0
  editor.moveCursor(3, extend = true)
  editor.moveCursor(1)
  doAssert editor.cursor == 3 and editor.anchor == 3
  editor.moveEnd(extend = true)
  doAssert editor.selectedText() == "def"
  editor.backspace()
  doAssert editor.value() == "abc"
  editor.moveHome(extend = true)
  editor.deleteForward()
  doAssert editor.value() == ""
  editor.backspace()
  editor.deleteForward()
  editor.moveCursor(int.high)
  editor.moveCursor(int.low)
  doAssert editor.cursor == 0

block:
  var editor: Editor
  editor.insert("é".repeat(MaxChatCharacters + 20))
  doAssert editor.text.len == MaxChatCharacters
  doAssert editor.value().validateUtf8() == -1
  editor.insert("ignored")
  doAssert editor.text.len == MaxChatCharacters
  editor.moveCursor(-2, extend = true)
  editor.insert("ABC")
  doAssert editor.text.len == MaxChatCharacters
  doAssert editor.value().endsWith("AB")
  editor.selectAll()
  editor.insert("Hi\n\r\t\0\x7f there\u2028!")
  doAssert editor.value() == "Hi there!"
  editor.selectAll()
  editor.insert("\n\r\t")
  doAssert editor.value() == "Hi there!"
  doAssert editor.selectedText() == "Hi there!"

block:
  var editor: Editor
  editor.insert("Safe")
  for invalid in ["\xff", "\xed\xa0\x80", "\xf4\x90\x80\x80",
    "\xe0\x80\xaf"]:
      var rejected = false
      try:
        editor.insert(invalid)
      except GeneralsError:
        rejected = true
      doAssert rejected
      doAssert editor.value() == "Safe"
  for rune in [Rune(-1), Rune(0xd800), Rune(0x110000)]:
    var rejected = false
    try:
      editor.insert(rune)
    except GeneralsError:
      rejected = true
    doAssert rejected
  editor.cursor = 999
  editor.anchor = -2
  doAssert editor.selectedText() == "Safe"
  editor.insert("X")
  doAssert editor.value() == "X"
  doAssert editor.selection() == (1, 1)

echo "Local chat editor checks passed"
