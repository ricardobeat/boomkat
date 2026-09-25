#!/usr/bin/env python3
"""Package native CLI binaries for one release platform."""

import argparse
import hashlib
import pathlib
import shutil
import tarfile
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent


def package(platform: str, binary_dir: pathlib.Path, dist: pathlib.Path) -> None:
    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    suffix = ".exe" if platform.startswith("windows-") else ""
    dist.mkdir(parents=True, exist_ok=True)
    hashes = []
    for kind in ("boomkat", "boomkat-slim"):
        built_name = "boomkat_slim" if kind == "boomkat-slim" else kind
        source = binary_dir / f"{built_name}{suffix}"
        if not source.is_file():
            raise FileNotFoundError(source)
        stem = f"{kind}-v{version}-{platform}"
        archive = dist / (stem + (".zip" if suffix else ".tar.gz"))
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp) / stem
            root.mkdir()
            shutil.copy2(source, root / source.name)
            shutil.copy2(ROOT / "LICENSE", root / "LICENSE")
            if suffix:
                with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zf:
                    for file in root.iterdir():
                        zf.write(file, f"{stem}/{file.name}")
            else:
                with tarfile.open(archive, "w:gz") as tf:
                    tf.add(root, arcname=stem)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        hashes.append(f"{digest}  {archive.name}\n")
        print(archive)

    library_names = ("boomkat.lib", "boomkat.a") if suffix else ("boomkat.a",)
    library = next((binary_dir / name for name in library_names if (binary_dir / name).is_file()), None)
    if library is None:
        raise FileNotFoundError(f"missing static library in {binary_dir}: {library_names}")
    stem = f"boomkat-lib-v{version}-{platform}"
    archive = dist / (stem + (".zip" if suffix else ".tar.gz"))
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp) / stem
        (root / "include").mkdir(parents=True)
        (root / "lib").mkdir()
        (root / "examples").mkdir()
        shutil.copy2(ROOT / "include" / "boomkat.h", root / "include" / "boomkat.h")
        shutil.copy2(ROOT / "bindings" / "c" / "hello_console.c", root / "examples" / "hello_console.c")
        shutil.copy2(ROOT / "LICENSE", root / "LICENSE")
        shutil.copy2(library, root / "lib" / library.name)
        if platform.startswith("linux-"):
            build_line = f"cc -std=c99 -Iinclude examples/hello_console.c lib/{library.name} -lm -ldl -o hello"
        elif platform.startswith("macos-"):
            build_line = f"cc -std=c99 -Iinclude examples/hello_console.c lib/{library.name} -o hello"
        else:
            build_line = f"cl /Iinclude examples\\hello_console.c lib\\{library.name}"
        (root / "README.txt").write_text(
            f"Boomkat v{version} C embedding library ({platform})\n\n"
            f"Build the included hello-world example:\n{build_line}\n\n"
            "The host adds console.log with bk_register_fn; the engine library leaves console unbound.\n",
            encoding="utf-8",
        )
        if suffix:
            with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zf:
                for file in root.rglob("*"):
                    if file.is_file():
                        zf.write(file, f"{stem}/{file.relative_to(root)}")
        else:
            with tarfile.open(archive, "w:gz") as tf:
                tf.add(root, arcname=stem)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    hashes.append(f"{digest}  {archive.name}\n")
    print(archive)
    (dist / f"SHA256SUMS-{platform}.txt").write_text("".join(hashes), encoding="ascii")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--binary-dir", type=pathlib.Path, default=ROOT / "out")
    parser.add_argument("--dist", type=pathlib.Path, default=ROOT / "dist" / "release")
    args = parser.parse_args()
    package(args.platform, args.binary_dir, args.dist)


if __name__ == "__main__":
    main()
