#!/usr/bin/env python3
"""Cache and run self-contained module entrypoints with existing bytecode tools.

The compiler must support --compile and the runner must accept one image path.
Imports, script-goal execution, and eval are outside this workflow's scope.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


IMAGE_HEADER = b'\x04\x00\x00\x00BKBC'
MAX_IMAGE_BYTES = 64 * 1024 * 1024
CACHE_NAME = re.compile(r'[0-9a-f]{64}\.bkbc\Z')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def image_digest(path):
    if not 24 <= path.stat().st_size <= MAX_IMAGE_BYTES:
        raise ValueError('invalid bytecode image size')
    image = path.read_bytes()
    if not image.startswith(IMAGE_HEADER):
        raise ValueError('invalid bytecode image header')
    return digest(image)


def cached_image(image, checksum, snapshot):
    try:
        # Publication replaces files rather than mutating their contents. This
        # link keeps the checked image alive until the child finishes using it.
        os.link(image, snapshot)
        return image_digest(snapshot) == checksum.read_text().strip()
    except (OSError, ValueError, UnicodeError):
        return False


def trim_cache(directory, max_entries, max_bytes):
    entries = []
    for path in directory.glob('*.bkbc'):
        if not CACHE_NAME.fullmatch(path.name):
            continue
        try:
            info = path.stat()
            entries.append((info.st_mtime_ns, path, info.st_size))
        except OSError:
            continue
    total = sum(size for _, _, size in entries)
    count = len(entries)
    for _, path, size in sorted(entries):
        if count <= max_entries and total <= max_bytes:
            break
        for candidate in (path, path.with_suffix('.sha256')):
            try:
                candidate.unlink(missing_ok=True)
            except OSError:
                pass
        total -= size
        count -= 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', type=Path, required=True)
    parser.add_argument('--runner', type=Path, required=True)
    parser.add_argument('--cache-dir', type=Path, required=True)
    parser.add_argument('--max-entries', type=int, default=32)
    parser.add_argument('--max-bytes', type=int, default=MAX_IMAGE_BYTES)
    parser.add_argument('--verbose', action='store_true')
    parser.add_argument('source', type=Path)
    args = parser.parse_args()
    if args.max_entries < 1 or args.max_bytes < 1:
        parser.error('cache bounds must be positive')

    compiler = args.compiler.resolve(strict=True)
    runner = args.runner.resolve(strict=True)
    source = args.source.resolve(strict=True)
    source_bytes = source.read_bytes()
    identity = {
        'format': 1, 'source': str(source), 'content': digest(source_bytes),
        'compiler': digest(compiler.read_bytes()),
        'runner': digest(runner.read_bytes()),
    }
    key = digest(json.dumps(identity, sort_keys=True).encode())
    cache = args.cache_dir.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    image = cache / (key + '.bkbc')
    checksum = image.with_suffix('.sha256')

    with tempfile.TemporaryDirectory(prefix='.run-', dir=cache) as temporary:
        temporary = Path(temporary)
        snapshot = temporary / 'entry.bkbc'
        hit = cached_image(image, checksum, snapshot)
        if not hit:
            snapshot.unlink(missing_ok=True)
            compiled = subprocess.run([str(compiler), '--compile', str(snapshot),
                                       str(source)])
            if compiled.returncode:
                return compiled.returncode
            content_hash = image_digest(snapshot)
            if source.read_bytes() != source_bytes:
                raise ValueError('source changed while compiling')
            if digest(compiler.read_bytes()) != identity['compiler']:
                raise ValueError('compiler changed while compiling')
            if snapshot.stat().st_size <= args.max_bytes:
                # Each publication is atomic. An interruption between the two
                # replacements leaves a checksum mismatch and a future miss.
                pending = temporary / 'publish.bkbc'
                os.link(snapshot, pending)
                os.replace(pending, image)
                pending = temporary / 'publish.sha256'
                pending.write_text(content_hash + '\n')
                os.replace(pending, checksum)
        if args.verbose:
            print('bytecode cache: ' + ('hit' if hit else 'miss'), file=sys.stderr)
        try:
            os.utime(image)
        except OSError:
            pass
        result = subprocess.run([str(runner), str(snapshot)])
        trim_cache(cache, args.max_entries, args.max_bytes)
        return result.returncode


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f'bytecode cache: {error}', file=sys.stderr)
        sys.exit(1)
