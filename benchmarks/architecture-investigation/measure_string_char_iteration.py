"""Measure string-iterator character churn against QuickJS and GC counters."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import statistics
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--boomkat', type=Path, default=Path('out/boomkat'))
parser.add_argument('--baseline', type=Path,
                    help='optional pre-change Boomkat binary for paired A/B runs')
parser.add_argument('--quickjs', type=Path, default=Path('out/qjs'))
parser.add_argument('--gcprofile', type=Path, default=Path('out/boomkat_gcprofile'))
parser.add_argument('--out', type=Path,
                    default=Path('benchmarks/architecture-investigation/string-char-iteration-results.json'))
parser.add_argument('--runs', type=int, default=7)
args = parser.parse_args()

cases = {
    'repeat_a_forof': ('a', 200_000, 'forof', 200_000),
    'alternating_ab_forof': ('ab', 100_000, 'forof', 200_000),
    'cycling_abcde_forof': ('abcde', 40_000, 'forof', 200_000),
    'repeat_a_indexed': ('a', 200_000, 'indexed', 200_000),
    'astral_forof': ('😀', 100_000, 'forof', 100_000),
}


def source_for(unit, repetitions, mode, run_loop):
    literal = json.dumps(unit, ensure_ascii=True)
    loop = ('for (const ch of text) count++;' if mode == 'forof' else
            'for (let i = 0; i < text.length; i++) if (text[i]) count++;')
    return f'''var text = {literal}.repeat({repetitions});
var count = 0;
var started = Date.now();
if ({'true' if run_loop else 'false'}) {{ {loop} }}
print("PHASE " + (Date.now() - started));
print("CHECK " + count);
'''


def run(command):
    start = time.perf_counter()
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    elapsed = (time.perf_counter() - start) * 1000
    if result.returncode:
        raise RuntimeError((command, result.stdout, result.stderr))
    return elapsed, result.stdout, result.stderr


rows = []
profiles = {}
bins = []
if args.baseline:
    bins.append(('baseline', args.baseline))
bins.extend([('boomkat', args.boomkat), ('quickjs', args.quickjs)])
with tempfile.TemporaryDirectory(prefix='boomkat-char-iteration-') as temp:
    temp = Path(temp)
    for case_name, (unit, repetitions, mode, expected_count) in cases.items():
        js_file = temp / f'{case_name}.js'
        js_file.write_text(source_for(unit, repetitions, mode, True))
        baseline_file = temp / f'{case_name}-baseline.js'
        baseline_file.write_text(source_for(unit, repetitions, mode, False))
        for rep in range(args.runs):
            order = bins[rep % len(bins):] + bins[:rep % len(bins)]
            if rep % 2:
                order.reverse()
            for variant in order:
                variant_name, binary = variant
                command = ([str(binary), '--script', str(js_file)] if variant_name != 'quickjs'
                           else [str(binary), str(js_file)])
                elapsed, stdout, _ = run(command)
                check = re.search(r'^CHECK (\d+)$', stdout, re.MULTILINE)
                if not check or int(check.group(1)) != expected_count:
                    raise RuntimeError((case_name, variant_name, stdout, expected_count))
                phase = re.search(r'^PHASE (\d+)$', stdout, re.MULTILINE)
                rows.append(dict(case=case_name, variant=variant_name, rep=rep,
                                 wall_ms=elapsed,
                                 phase_ms=int(phase.group(1)) if phase else None,
                                 check=int(check.group(1))))

        profile = {}
        for variant, file in [('baseline', baseline_file), ('iteration', js_file)]:
            _, stdout, stderr = run([str(args.gcprofile), str(file)])
            match = re.search(r'^# GC_ASCII_CHARS allocations=(\d+) frees=(\d+)$',
                              stderr, re.MULTILINE)
            if not match:
                raise RuntimeError(('missing GC_ASCII_CHARS counter', stdout, stderr))
            profile[variant] = dict(allocations=int(match.group(1)),
                                    frees=int(match.group(2)))
        profiles[case_name] = dict(
            baseline=profile['baseline'], iteration=profile['iteration'],
            iteration_alloc_delta=(profile['iteration']['allocations']
                                   - profile['baseline']['allocations']),
            iteration_free_delta=(profile['iteration']['frees']
                                  - profile['baseline']['frees']))

summary = {}
for name in cases:
    summary[name] = {}
    for variant, _ in bins:
        selected = [row for row in rows
                    if row['case'] == name and row['variant'] == variant]
        summary[name][variant] = dict(
            wall_ms_median=statistics.median(row['wall_ms'] for row in selected),
            phase_ms_median=statistics.median(row['phase_ms'] for row in selected))

out = args.out.resolve()
out.write_text(json.dumps(dict(
    description='Seven alternating string iteration/indexing runs; GC_PROFILE ASCII-character allocation/free deltas are measured against identical no-loop scripts.',
    binaries={name: dict(path=str(path.resolve()),
                         sha256=hashlib.sha256(path.read_bytes()).hexdigest())
              for name, path in bins + [('gcprofile', args.gcprofile)]},
    summary=summary, ascii_char_profile_deltas=profiles, runs=rows), indent=2) + '\n')
print(json.dumps(dict(summary=summary, ascii_char_profile_deltas=profiles), indent=2))
