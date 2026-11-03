' Expand from the strongest frontier in a bounded batch; globals persist.
' Rotate through at most 128 movable tiles to stay within the decision budget.
best = -2147483647
checked = 0
cells = height * width
for scanned = 1 to cells
  row = cursor \ width
  col = cursor mod width
  cursor = (cursor + 1) mod cells
  if owner(row, col) = 1 and army(row, col) > 1 then
    for direction = 0 to 3
      nextRow = row
      nextCol = col
      if direction = 0 then nextRow = row - 1
      if direction = 1 then nextRow = row + 1
      if direction = 2 then nextCol = col - 1
      if direction = 3 then nextCol = col + 1
      terrain = tileType(nextRow, nextCol)
      if terrain >= 0 and terrain <> 2 and terrain <> 5 then
        if owner(nextRow, nextCol) <> 1 then
          score = army(row, col) - army(nextRow, nextCol) - 1
          if terrain = 4 then score = score + 10000
          if score > best then
            best = score
            bestRow = row
            bestCol = col
            bestDirection = direction
          end if
        end if
      end if
    next direction
    checked = checked + 1
    if checked = 128 then exit for
  end if
next scanned
if best > 0 then accepted = move(bestRow, bestCol, bestDirection, 0)
