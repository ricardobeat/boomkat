"""Create isolated copies of the measured revision and apply experiment patches."""

import argparse
import io
import json
from pathlib import Path
import subprocess
import tarfile


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
VARIANTS = (
    "baseline", "mul", "arrays", "slots", "clock64", "clock128",
    "clockpoll128", "combined",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=False)
    revision = json.loads((HERE / "manifest.json").read_text())["revision"]
    archive = subprocess.check_output(["git", "archive", revision], cwd=ROOT)
    for variant in VARIANTS:
        destination = args.directory / variant
        destination.mkdir()
        with tarfile.open(fileobj=io.BytesIO(archive)) as source:
            source.extractall(destination, filter="data")
        patches = ["benchmark-clock"]
        if variant != "baseline":
            patches.append(variant)
        for patch in patches:
            with (HERE / "patches" / f"{patch}.patch").open() as source:
                subprocess.run(
                    ["patch", "-p1"], cwd=destination, stdin=source, check=True,
                )
        # Exercise threaded handlers under the existing ASAN + GC_VERIFY target.
        project = destination / "project.json"
        config = json.loads(project.read_text())
        config["targets"]["test_gc_incremental"]["features"].append("THREADED_DISPATCH")
        project.write_text(json.dumps(config, indent=2) + "\n")
    print(args.directory.resolve())


if __name__ == "__main__":
    main()
