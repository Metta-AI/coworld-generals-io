' Expand from the strongest frontier. One action per turn; globals persist.
best = -2147483647
for row = 0 to height - 1
  for col = 0 to width - 1
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
    end if
  next col
next row
if best > 0 then accepted = move(bestRow, bestCol, bestDirection, 0)
