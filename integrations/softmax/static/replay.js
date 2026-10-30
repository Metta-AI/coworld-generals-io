/* Versioned recordings: published full frames and seekable keyframe/delta frames. */
function GeneralsReplay(data) {
  const grids = ['type_grid', 'owner_grid', 'army_grid'];
  if (data.format !== 'generals-coworld' || ![1, 2].includes(data.version) ||
      !Array.isArray(data.frames) || !data.frames.length || data.frames.length > 50004 ||
      !Number.isInteger(data.height) || !Number.isInteger(data.width) || data.height < 1 || data.height > 33 || data.width < 1 || data.width > 33 ||
      !Array.isArray(data.players) || data.players.length < 2 || data.players.length > 8 || !data.result) {
    throw new Error('Unsupported or incomplete Generals replay.');
  }
  const bases = [];
  let base = 0;
  data.frames.forEach((record, index) => {
    if (data.version === 2 && 'grid_delta' in record) {
      if (index === 0 || index - base > 255 || !Array.isArray(record.grid_delta) || record.grid_delta.some(change =>
          !Array.isArray(change) || change.length !== 4 || change.some(n => !Number.isInteger(n)) ||
          change[0] < 0 || change[0] >= data.height * data.width || change[1] < 1 || change[1] > 4 ||
          change[2] < 0 || change[2] > data.players.length || change[3] < 0)) {
        throw new Error('Replay contains invalid tile changes.');
      }
    } else {
      for (const key of grids) {
        if (!Array.isArray(record[key]) || record[key].length !== data.height || record[key].some(row =>
            !Array.isArray(row) || row.length !== data.width || row.some(n => !Number.isInteger(n)))) {
          throw new Error('Replay contains an invalid board.');
        }
      }
      base = index;
    }
    bases.push(base);
  });
  let cachedIndex = -1, decoded;
  return index => {
    const start = cachedIndex >= bases[index] && cachedIndex <= index ? cachedIndex + 1 : bases[index];
    for (let i = start; i <= index; i++) {
      const record = data.frames[i];
      if (i === bases[i]) {
        decoded = Object.fromEntries(grids.map(key => [key, record[key].map(row => row.slice())]));
      } else {
        for (const [cell, kind, owner, army] of record.grid_delta) {
          const row = Math.floor(cell / data.width), col = cell % data.width;
          decoded.type_grid[row][col] = kind;
          decoded.owner_grid[row][col] = owner;
          decoded.army_grid[row][col] = army;
        }
      }
    }
    cachedIndex = index;
    return {...data.frames[index], ...decoded};
  };
}
