#!/usr/bin/env python3
"""Measure live, statically linked English ICU formatter paths in Boomkat.

Requires ICU 78.3 source and data archives extracted into SOURCE. The source
data must include data/locales/root.txt, and data/in/*.dat must be removed:
ICU otherwise bypasses its data filter. See scripts/icu_size/README.md.
"""
import argparse
import copy
import json
import os
import platform
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FLAGS = [
    "UCONFIG_NO_COLLATION", "UCONFIG_NO_BREAK_ITERATION",
    "UCONFIG_NO_TRANSLITERATION", "UCONFIG_NO_REGULAR_EXPRESSIONS",
    "UCONFIG_NO_LEGACY_CONVERSION", "UCONFIG_NO_IDNA", "UCONFIG_NO_SERVICE",
    "UCONFIG_NO_MF2",
]


def run(args, cwd, log, env=None):
    with log.open("a") as stream:
        stream.write("\n" + " ".join(map(str, args)) + "\n")
        stream.flush()
        subprocess.run(list(map(str, args)), cwd=cwd, env=env,
                       stdout=stream, stderr=subprocess.STDOUT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=ROOT / "out/icu-size")
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--profiles", nargs="+", choices=["baseline", "numbers", "dates"],
                        default=["baseline", "numbers", "dates"])
    parser.add_argument("--no-intl", action="store_true", help="Exclude native Intl from the engine snapshot")
    parser.add_argument("--no-intl-date", action="store_true", help="Exclude native DateTimeFormat only")
    args = parser.parse_args()
    source = args.source.resolve()
    work = args.out.resolve()
    work.mkdir(parents=True, exist_ok=True)
    if platform.system() != "Darwin":
        parser.error("This measurement currently uses macOS strip/link flags")
    if not (source / "data/locales/root.txt").exists():
        parser.error("Extract the official ICU data sources into source/data first")
    if list((source / "data/in").glob("*.dat")):
        parser.error("Remove prebuilt source/data/in/*.dat so ICU applies the filter")
    version = (source / "common/unicode/uvernum.h").read_text()
    if '#define U_ICU_VERSION "78.3"' not in version:
        parser.error("This benchmark is pinned to ICU 78.3")
    base_project = json.loads((ROOT / "project.json").read_text())
    # Every profile compiles the same engine snapshot, even during development.
    engine = Path(tempfile.mkdtemp(prefix="engine-", dir=work))
    for directory in ("src", "cli"):
        shutil.copytree(ROOT / directory, engine / directory)
    def source_path(path):
        return str((engine if Path(path).parts[0] in ("src", "cli") else ROOT) / path)
    results = {"platform": platform.platform(), "machine": platform.machine(),
               "icu": "78.3", "profiles": {}}
    for profile in dict.fromkeys(["baseline"] + args.profiles):
        build = work / profile
        build.mkdir(exist_ok=True)
        project = copy.deepcopy(base_project)
        project["c-sources"] = [source_path(p) for p in project["c-sources"]]
        project["c-include-dirs"] = [str(ROOT / p) for p in project["c-include-dirs"]]
        target = copy.deepcopy(project["targets"]["boomkat"])
        if args.no_intl:
            target.setdefault("features", []).append("NO_INTL")
        if args.no_intl_date:
            target.setdefault("features", []).append("NO_INTL_DATE")
        target["name"] = "boomkat-" + profile
        target["sources"] = [source_path(p) for p in target["sources"]]
        target["link-args"] = ["-Wl,-dead_strip", "-Wl,-exported_symbols_list," +
                               str(ROOT / "scripts/no_exports.exp")]
        data_bytes = 0
        if profile != "baseline":
            config = json.loads((ROOT / "scripts/icu_size/filter.json").read_text())
            if profile == "dates":
                config["resourceFilters"][0]["rules"] += [
                    "+/calendar/gregorian", "+/calendar/generic", "+/fields",
                    "+/contextTransforms", "+/DateTimePatterns",
                ]
                # Fixed-offset zones use Boomkat's tzdb instead of ICU zoneinfo.
                config["featureFilters"]["misc"]["includelist"] += ["dayPeriods", "supplementalData"]
            config_path = build / "filter.json"
            config_path.write_text(json.dumps(config, indent=2) + "\n")
            env = os.environ.copy()
            env.update(ICU_DATA_FILTER_FILE=str(config_path),
                       CFLAGS="-Oz -ffunction-sections -fdata-sections",
                       CXXFLAGS="-Oz -ffunction-sections -fdata-sections",
                       CPPFLAGS=" ".join("-D" + f + "=1" for f in FLAGS))
            icu_build = build / "icu"
            icu_build.mkdir(exist_ok=True)
            log = build / "icu.log"
            run([source / "runConfigureICU", "MacOSX", "--enable-static",
                 "--disable-shared", "--disable-tests", "--disable-samples",
                 "--disable-extras", "--with-data-packaging=static"], icu_build, log, env)
            # ICU's generated data rules do not track changes to the filter.
            run(["make", "-C", "data", "clean"], icu_build, log, env)
            run(["make", f"-j{args.jobs}"], icu_build, log, env)
            target["c-sources"] = [str(ROOT / "scripts/icu_size/probe.c")]
            target["c-include-dirs"] = [str(source / "common"), str(source / "i18n")]
            target["cflags"] = "-Oz -DU_STATIC_IMPLEMENTATION " + env["CPPFLAGS"]
            if profile == "dates":
                target["cflags"] += " -DBK_ICU_DATES"
            target["link-args"] += [str(icu_build / "lib" / name) for name in
                                    ("libicui18n.a", "libicuuc.a", "libicudata.a")]
            target["linked-libraries"] = ["c++"]
            packages = list((icu_build / "data/out").rglob("icudt*.dat"))
            if len(packages) != 1:
                raise RuntimeError(f"Expected one ICU data package, found {packages}")
            data_bytes = packages[0].stat().st_size
        project["targets"] = {"measure": target}
        (build / "project.json").write_text(json.dumps(project, indent=2) + "\n")
        log = build / "engine.log"
        run(["c3c", "build", "measure"], build, log)
        binary = build / "out" / target["name"]
        run(["strip", "-x", binary], build, log)
        if profile != "baseline":
            env = os.environ.copy()
            env["BK_ICU_SIZE_PROBE"] = "1"
            smoke = build / "smoke.js"
            smoke.write_text('console.log("Boomkat probe passed");\n')
            probe_log = build / "probe.log"
            probe_log.unlink(missing_ok=True)
            run([binary, "--script", smoke], ROOT, probe_log, env)
            probe = (build / "probe.log").read_text()
            if "ICU probe passed" not in probe or "Boomkat probe passed" not in probe:
                raise RuntimeError("Formatter/engine smoke probe did not finish")
        size = binary.stat().st_size
        baseline = results["profiles"].get("baseline", {}).get("binary_bytes", size)
        results["profiles"][profile] = {"binary_bytes": size,
            "added_bytes": size - baseline, "data_package_bytes": data_bytes}
        (work / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(profile, results["profiles"][profile], flush=True)


if __name__ == "__main__":
    main()
