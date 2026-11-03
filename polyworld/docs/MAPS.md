# Seeded maps

Every FFA player count from 2 through 10 is supported. The same seed,
player count, dimensions, and map-generation version produce exactly the
same tiles, city armies, and player starts. The generator uses a private
xorshift32 stream, so creating another game or running bots cannot affect it.
Seeds are integers from 0 through 2147483647.

Default dimensions depend on both the seed and player count. Ten-player
maps are approximately 26 to 35 tiles per side. Engine JSON can override
`width` and `height` independently, from 13 through 61. Omitted or zero
values use automatic sizing. Explicit dimensions remain fixed when the
seed or player count changes. Small custom maps may not fit all the
required general separations and report a `GeneralsError`.

```sh
./out/generals --play --players=10 --seed=7
./out/generals --headless --players=7 --seed=123 --record=out/seven.replay
./out/generals --replay=out/seven.replay
```

# Generation rules

Maps are asymmetric, with random general positions. Each player starts
with one general, one army, and an ordinary-land exit. Pairwise minimum
Manhattan distances are:

| Players | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Distance | 15 | 14 | 13 | 12 | 11 | 10 | 10 | 10 | 10 |

Every general can reach every other without crossing mountains, cities,
or a third general. Unrelated enclosed land pockets are allowed.

Mountain placement attempts use a 20–28% area budget plus the city
allowance. Duplicate obstacle selections and cities replacing mountains
mean this is not an exact final mountain percentage. City counts target
roughly `5 + players × (2 + random)`, with neutral garrisons from 40 to 50.

Two-player starts balance weighted accessible land within fourteen steps.
Nearby cities come in opposite-favored pairs with matching garrisons and
walking distances. Equal-distance cities and sufficiently distant cities
can be unpaired. The final placement is checked again after cities open
potential routes. A balanced map can have fewer cities than the target.

Larger FFA maps give each general an accessible city within six steps,
using the same initial garrison for each player's first city, then fill
the remaining city budget randomly. This follows the original FFA
fallback placement rules and keeps the nearby-city guarantee for nine
and ten players as well.

The original game's random layouts are not reproduced byte for byte.
Local generation uses bounded retries, stricter duel expansion balance,
and a simpler FFA city placement policy. It never relaxes general spacing
or silently enlarges explicitly requested dimensions. If 256 terrain
attempts cannot produce a valid layout, creation raises `GeneralsError`.

Replays store concrete dimensions, the seed, and a generator version.
Old version 1 and 2 recordings retain the previous reflected generator.
New recordings use the asymmetric generator and standard Polyworld
lockstep action replay.
