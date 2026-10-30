"""Bounded keyframes and sparse grid changes for long, seekable recordings."""

import numpy as np

REPLAY_VERSION = 2
KEYFRAME_INTERVAL = 256
GRIDS = ("type_grid", "owner_grid", "army_grid")


def replay_frame(records: list[dict], index: int) -> dict:
    """Decode one frame, also accepting full frames in published v1 recordings."""
    index %= len(records)
    base = index
    while "grid_delta" in records[base]:
        base -= 1
    frame = dict(records[base])
    for key in GRIDS:
        frame[key] = [row.copy() for row in frame[key]]
    width = len(frame["type_grid"][0])
    for record in records[base + 1:index + 1]:
        for cell, kind, owner, army in record["grid_delta"]:
            row, col = divmod(cell, width)
            for key, value in zip(GRIDS, (kind, owner, army)):
                frame[key][row][col] = value
    return {**frame, **{key: value for key, value in records[index].items() if key not in (*GRIDS, "grid_delta")}}


class ReplayFrames:
    def __init__(self, first: dict):
        self.records = [first]
        self.last = first

    def __len__(self):
        return len(self.records)

    def __getitem__(self, index):
        if isinstance(index, slice):
            return [self[i] for i in range(*index.indices(len(self)))]
        if not -len(self) <= index < len(self):
            raise IndexError(index)
        return self.last if index in (-1, len(self) - 1) else replay_frame(self.records, index)

    def append(self, frame: dict):
        if len(self) % KEYFRAME_INTERVAL == 0:
            record = frame
        else:
            before = np.asarray([self.last[key] for key in GRIDS]).reshape(3, -1)
            after = np.asarray([frame[key] for key in GRIDS]).reshape(3, -1)
            changed = np.flatnonzero(np.any(before != after, axis=0))
            record = {key: value for key, value in frame.items() if key not in GRIDS}
            record["grid_delta"] = np.column_stack((changed, after[:, changed].T)).tolist()
        self.records.append(record)
        self.last = frame
