#!/usr/bin/env python3
"""Build/run plan 105's temporary metadata CLI without editing engine sources."""

import argparse
import hashlib
import json
import platform
from pathlib import Path
import subprocess
import time


WORKLOADS = [
    'test/benchmarks/bench_ic_monomorphic.js',
    'test/benchmarks/bench_ic_proto.js',
    'bench/mini/richards.js',
    'bench/mini/deltablue.js',
    'test/benchmarks/bench_scene_churn.js',
    'bench/mini/typescript.js',
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--binary', type=Path,
                        help='existing plan-105 diagnostic binary; skip build')
    parser.add_argument('--compiler', default='c3c')
    args = parser.parse_args()
    repo = args.repo.resolve()
    output = args.out.resolve()
    if output == repo or repo in output.parents:
        parser.error('--out must be outside the selected engine checkout')
    missing = [name for name in WORKLOADS if not (repo / name).is_file()]
    if missing:
        parser.error('missing workloads: ' + ', '.join(missing))
    if output.exists() and any(output.iterdir()):
        parser.error('--out must be a new or empty directory')
    output.mkdir(parents=True, exist_ok=True)

    build_command = None
    generated_project = None
    if args.binary:
        binary = args.binary.resolve()
    else:
        source = (repo / 'cli/boomkat.c3').read_text()
        anchor = '    hp.set_rejection_tracker(&cli_rejection_tracker, null);'
        if source.count(anchor) != 1:
            raise RuntimeError('CLI hook anchor changed; audit probe placement')
        source = source.replace(anchor,
                                '    defer dump_shape_study(hp);\n' + anchor)
        source += '\n' + Path(__file__).with_name('probe.c3').read_text()
        cli = output / 'study.c3'
        cli.write_text(source)

        generated_project = json.loads((repo / 'project.json').read_text())
        for key in ('c-sources', 'c-include-dirs'):
            generated_project[key] = [str(repo / path)
                                      for path in generated_project.get(key, [])]
        target = dict(generated_project['targets']['boomkat'])
        target['name'] = 'shape-study'
        target['sources'] = [str(repo / 'src'), str(cli)]
        generated_project['targets'] = {'study': target}
        (output / 'project.json').write_text(
            json.dumps(generated_project, indent=2) + '\n')
        build_command = [args.compiler, 'build', 'study',
                         '--build-dir', 'out/build/study']
        (output / 'out/build/study').mkdir(parents=True)
        with (output / 'build.log').open('w') as log:
            subprocess.run(build_command, cwd=output, stdout=log,
                           stderr=subprocess.STDOUT, check=True)
        binary = output / 'out/shape-study'

    metadata = {
        'revision': subprocess.check_output(
            ['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
        'compiler': subprocess.check_output(
            [args.compiler, '--version'], text=True),
        'platform': platform.platform(),
        'binary': str(binary),
        'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
        'build_command': build_command,
        'project': generated_project,
        'purpose': ('End-of-run requested metadata bytes; elapsed times are '
                    'diagnostic data, not release performance evidence.'),
        'workloads': {name: hashlib.sha256((repo / name).read_bytes()).hexdigest()
                      for name in WORKLOADS},
    }
    (output / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    results = []
    for name in WORKLOADS:
        command = [str(binary), '--script', str(repo / name)]
        start = time.monotonic()
        result = subprocess.run(command, capture_output=True, text=True,
                                timeout=120)
        row = {'workload': name, 'command': command,
               'returncode': result.returncode, 'stdout': result.stdout,
               'stderr': result.stderr,
               'diagnostic_elapsed': time.monotonic() - start}
        results.append(row)
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(name, result.returncode, flush=True)
        if result.returncode or 'FAIL' in result.stdout:
            raise RuntimeError(f'workload failed: {name}\n{result.stderr}')
        required = ('STUDY sizes ', 'STUDY functions ', 'STUDY shapes ')
        if not all(marker in result.stderr for marker in required):
            raise RuntimeError(f'not a plan-105 diagnostic binary: {binary}')


if __name__ == '__main__':
    main()
