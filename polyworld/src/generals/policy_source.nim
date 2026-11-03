## Lowers the two published Generals coordinate spellings into one host ABI.
## Existing uploaded policies use row/column queries; Polyworld uses tile indices.
import std/[strutils, tables, sets]

const PolicyData* = ["turn", "slot", "height", "width", "max_turns",
  "my_land", "my_army", "opp_land", "opp_army"]

const PolicyFunctions* = [
  ("playerName$", 1), ("mailboxName$", 1), ("sendChat", 2),
  ("pullMailbox$", 0), ("selfPlayer", 0), ("playerCount", 0),
  ("playerInfoEnabled", 0), ("playerMmr", 1), ("worldTick", 0),
  ("worldTurn", 0), ("width", 0), ("height", 0), ("tileCount", 0),
  ("selfGeneral", 0), ("visible", 1), ("terrain", 1), ("owner", 1),
  ("army", 1), ("mailboxId", 0), ("mailboxCount", 0),
  ("mailboxSelf", 0), ("mailboxPlayers", 0), ("send", 3),
  ("tileType", 2), ("owner", 2), ("visibleOwner", 2), ("army", 2),
  ("buildCost", 2), ("playerArmy", 1), ("playerLand", 1),
  ("playerEliminated", 1), ("playerRated", 1), ("playerSkill", 1),
  ("move", 4), ("buildCastle", 2), ("pass", 0)
]

proc policyFunctionName*(name: string, count: int): string =
  ## Keeps functions distinct from legacy scalar data and policy variables.
  let text = name.toLowerAscii()
  if text.endsWith("$"):
    "g" & text[0 ..< text.high] & $count & "$"
  else:
    "g" & text & $count

proc policySource*(source: string): string =
  ## Resolves calls by arity without changing comments, strings, or line numbers.
  type Token = tuple[text: string, first, last: int]
  var
    tokens: seq[Token]
    position = 0
  while position < source.len:
    let first = position
    case source[position]
    of '"':
      inc position
      while position < source.len:
        if source[position] == '"':
          inc position
          if position == source.len or source[position] != '"': break
        inc position
    of '\'':
      while position < source.len and source[position] notin {'\r', '\n'}:
        inc position
    of 'a' .. 'z', 'A' .. 'Z', '_':
      while position < source.len and source[position] in
          {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '$'}:
        inc position
      let text = source[first ..< position].toLowerAscii()
      if text == "rem":
        while position < source.len and source[position] notin {'\r', '\n'}:
          inc position
      else:
        tokens.add((text, first, position))
    of ' ', '\t':
      inc position
    else:
      inc position
      tokens.add((source[first ..< position], first, position))

  var logical: seq[Token]
  var index = 0
  while index < tokens.len:
    if tokens[index].text == "_" and index + 1 < tokens.len and
        tokens[index + 1].text in ["\r", "\n"]:
      index += 2
      while index < tokens.len and tokens[index].text in ["\r", "\n"]:
        inc index
    else:
      logical.add(tokens[index])
      inc index
  tokens = move(logical)

  var
    calls: seq[tuple[name, count: int]]
    replacements: Table[int, string]
    assigned: HashSet[string]
  # A standalone policy may use `turn` as its own variable. Only free scalar
  # names denote the old read-only input data; assignments and SUB parameters
  # retain their normal BASIC meaning.
  var parameters = false
  for index, token in tokens:
    if token.text == "sub": parameters = true
    if token.text in ["\r", "\n", ":"]: parameters = false
    if token.text notin PolicyData: continue
    if parameters or (index > 0 and tokens[index - 1].text in ["for", "dim"]):
      assigned.incl(token.text)
    if index + 1 < tokens.len and tokens[index + 1].text == "=":
      var previous = index - 1
      while previous >= 0 and tokens[previous].text.allCharsInSet({'0' .. '9'}):
        dec previous
      if previous < 0 or tokens[previous].text in
          ["\r", "\n", ":", "then", "else", "let"]:
        assigned.incl(token.text)
  for index, token in tokens:
    case token.text
    of "(":
      calls.add((index - 1, if index + 1 < tokens.len and
        tokens[index + 1].text != ")": 1 else: 0))
    of ",":
      if calls.len > 0: inc calls[^1].count
    of ")":
      if calls.len == 0: continue # Bassy reports malformed syntax.
      let call = calls.pop()
      if call.name < 0: continue
      for (name, count) in PolicyFunctions:
        if tokens[call.name].text == name.toLowerAscii() and call.count == count:
          replacements[call.name] = policyFunctionName(name, count)
          break
    else:
      discard
  var copied = 0
  for index, token in tokens:
    if token.text in PolicyData and token.text notin assigned and
        (index == 0 or tokens[index - 1].text notin [".", "goto", "gosub", "restore"]) and
        (index + 1 == tokens.len or tokens[index + 1].text notin ["(", "as", ":"]):
      replacements[index] = "g" & token.text
    if replacements.hasKey(index):
      result.add(source[copied ..< token.first])
      result.add(replacements[index])
      copied = token.last
  result.add(source[copied ..< source.len])
