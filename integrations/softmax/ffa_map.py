"""Seeded base-game FFA maps with generals.io's size and placement rules.

Map sampling runs once before the JAX match starts. Mountains are sampled with
replacement, then cities replace mountains; the requested mountain budget is
therefore larger than the final mountain count. Invalid maps are resampled,
without carving terrain or relaxing spawn separation.
"""

import math
import random
from collections import deque
from collections.abc import Callable

import numpy as np


class FfaMapGenerator:
    def __init__(self, num_players: int, draw: Callable[[], float]):
        if not 3 <= num_players <= 8:
            raise ValueError("FFA requires three to eight players")
        self.num_players = num_players
        self.draw = draw

    def shuffle(self, values: list) -> None:
        for remaining in range(len(values), 0, -1):
            index = int(self.draw() * remaining)
            values[remaining - 1], values[index] = values[index], values[remaining - 1]

    def distance(self, first: int, second: int) -> int:
        ar, ac = divmod(first, self.width)
        br, bc = divmod(second, self.width)
        return abs(ar - br) + abs(ac - bc)

    def generate(self) -> np.ndarray:
        for _ in range(100000):
            if self.sample():
                grid = np.asarray(self.tiles, dtype=np.int32).reshape(self.height, self.width).copy()
                for index, army in self.cities.items():
                    grid.flat[index] = army
                return grid
        raise RuntimeError("FFA map generation exhausted its attempt limit")

    def sample(self) -> bool:
        count = self.num_players
        base = 16 + count + max(0, count - 6) / 2
        self.width = math.floor(base + self.draw() ** 2 * (4 + count / 2) + 0.5)
        self.height = math.floor(base + self.draw() ** 2 * (4 + count / 2) + 0.5)
        size = self.width * self.height
        self.tiles = [0] * size
        self.cities: dict[int, int] = {}
        self.generals: list[int] = []
        self.neighbors: list[list[int]] = []
        for index in range(size):
            row, col = divmod(index, self.width)
            adjacent = [other for other, valid in (
                (index - self.width, row > 0), (index + self.width, row + 1 < self.height),
                (index - 1, col > 0), (index + 1, col + 1 < self.width),
            ) if valid]
            self.shuffle(adjacent)
            self.neighbors.append(adjacent)

        desired_cities = 5 + count * (2 + self.draw())
        mountains = math.ceil(size * (0.2 + 0.08 * self.draw()) + desired_cities)
        for _ in range(mountains):
            self.tiles[int(self.draw() * size)] = -2

        if not self.place_generals():
            return False
        for _ in range(8):
            for index in self.cities:
                self.tiles[index] = -2
            self.cities.clear()
            if self.place_cities(desired_cities) and self.valid():
                return True
        return False

    def place_generals(self) -> bool:
        order = list(range(self.num_players))
        self.shuffle(order)
        positions = [0] * self.num_players
        chosen: list[int] = []
        separation = max(9, 9 * (1.8 - 0.1 * self.num_players))
        for player in order:
            for _ in range(1000):
                index = int(self.draw() * len(self.tiles))
                while self.tiles[index] == -2 or not any(self.tiles[n] == 0 for n in self.neighbors[index]):
                    index = int(self.draw() * len(self.tiles))
                if all(self.distance(index, other) > separation for other in chosen):
                    positions[player] = index
                    chosen.append(index)
                    break
            else:
                return False
        self.generals = positions
        for player, index in enumerate(positions):
            self.tiles[index] = player + 1
        return True

    def place_cities(self, desired: float) -> bool:
        count = self.num_players
        desired = math.floor(desired + 0.5)
        mountain_count = self.tiles.count(-2)
        amounts = [math.floor(40 + 10 * self.draw() + 0.5) for _ in range(desired)]
        nearby_limit = max(6, max(self.height, self.width) / (2 + math.log(count)))
        target = desired - count // 2
        spawn_rate = desired / mountain_count
        base_rate = 0.1 * spawn_rate
        reduction = 10 * count * base_rate * math.sqrt(0.5)
        increment = reduction / (count - 1)
        owned = [0] * count
        thresholds = [1 - base_rate] * count
        placed = 0

        for iteration in range(1, 52):
            if placed >= target and len(set(owned)) == 1:
                return sum(owned) > 0 or self.place_remaining_cities(desired)
            if placed >= target:
                largest = max(owned)
                thresholds = [10.0 if owned[p] == largest else thresholds[p] for p in range(count)]
            if iteration > 50 or (iteration > 25 and placed < target and count <= 4):
                return self.place_remaining_cities(desired)

            visited = set(self.generals)
            queue = deque((index, 0, player) for player, index in enumerate(self.generals))
            while queue:
                index, depth, player = queue.popleft()
                if iteration > 1 and depth >= nearby_limit:
                    continue
                if self.tiles[index] == -2:
                    near = thresholds[player] < 1 and 0 < depth < nearby_limit
                    far = depth >= nearby_limit and iteration == 1
                    if (near and self.draw() >= thresholds[player]) or (far and self.draw() >= 1 - spawn_rate):
                        self.tiles[index] = 0
                        self.cities[index] = (
                            amounts[owned[player]] if depth < nearby_limit
                            else math.floor(40 + 10 * self.draw() + 0.5)
                        )
                        placed += 1
                        if depth < nearby_limit:
                            owned[player] += 1
                            thresholds = [thresholds[p] + reduction if p == player else thresholds[p] - increment
                                          for p in range(count)]
                        if placed >= target:
                            break
                else:
                    for neighbor in self.neighbors[index]:
                        if neighbor not in visited and self.tiles[neighbor] <= 0:
                            visited.add(neighbor)
                            queue.append((neighbor, depth + 1, player))
        raise AssertionError("unreachable city placement iteration")

    def place_remaining_cities(self, desired: int) -> bool:
        candidates = [index for index, tile in enumerate(self.tiles) if tile == -2]
        self.shuffle(candidates)
        chosen: list[int] = []
        for general in self.generals:
            for index in candidates:
                if index not in chosen and self.distance(general, index) <= 6:
                    chosen.append(index)
                    break
        for index in candidates:
            if len(chosen) >= desired:
                break
            if index not in chosen:
                chosen.append(index)
        for index in chosen:
            self.tiles[index] = 0
            self.cities[index] = math.floor(40 + 10 * self.draw() + 0.5)
        return bool(chosen)

    def valid(self) -> bool:
        if len(self.cities) >= self.num_players and any(
            not any(self.distance(general, city) <= 6 for city in self.cities) for general in self.generals
        ):
            return False
        # Cities and other generals cannot be crossed during spawn validation.
        # Connecting every general to the first two excludes blocked-in spawns.
        for target in self.generals[:2]:
            visited = {target}
            queue = deque([target])
            reached = {target}
            while queue:
                for neighbor in self.neighbors[queue.popleft()]:
                    if neighbor in visited or neighbor in self.cities or self.tiles[neighbor] == -2:
                        continue
                    visited.add(neighbor)
                    if self.tiles[neighbor] > 0:
                        reached.add(neighbor)
                    else:
                        queue.append(neighbor)
            if len(reached) != self.num_players:
                return False
        return True


def generate_ffa_grid(seed: int, num_players: int) -> np.ndarray:
    return FfaMapGenerator(num_players, random.Random(seed).random).generate()
