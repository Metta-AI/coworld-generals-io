"""Import changes from Polyworld's current main branch, preserving adapter edits."""

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
RECORD = ROOT / "integrations/softmax/polyworld-upstream.txt"
UPSTREAM = "https://github.com/Metta-AI/polyworld-generals.git"


def main():
    previous = RECORD.read_text().strip()
    subprocess.run(["git", "fetch", "--no-tags", UPSTREAM, "main"], cwd=ROOT, check=True)
    current = subprocess.check_output(["git", "rev-parse", "FETCH_HEAD"], cwd=ROOT, text=True).strip()
    changes = subprocess.check_output(["git", "diff", "--binary", previous, current], cwd=ROOT)
    if changes:
        command = ["git", "apply", "--directory=polyworld"]
        subprocess.run([*command, "--check"], input=changes, cwd=ROOT, check=True)
        subprocess.run(command, input=changes, cwd=ROOT, check=True)
        RECORD.write_text(current + "\n")
    print(f"Polyworld main: {current}")


if __name__ == "__main__":
    main()
