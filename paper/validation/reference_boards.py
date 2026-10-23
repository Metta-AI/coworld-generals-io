"""Export private ReplaySimulationCore boards for board_diff.py / ffa/board_diff_ffa.py."""

import argparse
import glob
import hashlib
import json
import re
import subprocess
from pathlib import Path

import gior


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine_dir", type=Path, help="external directory containing the four reference JS files")
    parser.add_argument("pattern", help="quoted glob of .gior replays")
    parser.add_argument("output_dir", type=Path, help="new directory outside the source checkout")
    args = parser.parse_args()
    paths = sorted(glob.glob(args.pattern))
    if not paths:
        parser.error("no replays matched")
    checkout = Path(__file__).resolve().parents[2]
    if args.output_dir.resolve().is_relative_to(checkout):
        parser.error("reference snapshots must be stored outside the source checkout")
    args.output_dir.mkdir(parents=True, exist_ok=False)
    for filename in paths:
        source = Path(filename).read_bytes()
        replay = gior.deserialize(source)
        if replay["version"] not in (16, 17, 18):
            raise ValueError(f"{filename}: only replay versions 16–18 are supported by this adapter")
        if not re.fullmatch(r"[A-Za-z0-9_-]+", replay["id"]):
            raise ValueError(f"{filename}: invalid replay ID")
        # The existing comparison tools model base-game boards, not event modifiers.
        for field in (
            "modifiers",
            "lights",
            "observatories",
            "lookouts",
            "deserts",
            "swamps",
            "tunnels",
            "strongholds",
            "neutrals",
        ):
            if replay[field]:
                raise ValueError(f"{filename}: unsupported base-game feature: {field}")
        replay["moves"] = [
            dict(zip(("index", "start", "end", "is50", "turn"), move, strict=True)) for move in replay["moves"]
        ]
        replay["chat"] = [
            dict(zip(("text", "prefix", "playerIndex", "turn"), chat, strict=True)) for chat in replay["chat"]
        ]
        replay["generalTrades"] = [
            dict(zip(("playerIndexA", "playerIndexB", "turn"), trade, strict=True)) for trade in replay["generalTrades"]
        ]
        if replay["playerColors"] is None:
            replay["playerColors"] = list(range(len(replay["generals"])))
        result = subprocess.run(
            ["node", str(Path(__file__).with_name("reference_core.cjs")), str(args.engine_dir.resolve())],
            input=json.dumps(replay),
            text=True,
            capture_output=True,
            timeout=120,
        )
        if result.returncode:
            raise RuntimeError(f"{filename}: reference core failed:\n{result.stderr}")
        boards = json.loads(result.stdout)
        boards["replay_sha256"] = hashlib.sha256(source).hexdigest()
        boards["adapter_sha256"] = {
            name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
            for name in ("reference_boards.py", "reference_core.cjs", "gior.py")
        }
        with (args.output_dir / f"{replay['id']}.json").open("x") as output:
            json.dump(boards, output)
        print(f"{replay['id']}: {boards['turns']} turns, {boards['consumed']} moves, winners {boards['winner']}")


if __name__ == "__main__":
    main()
