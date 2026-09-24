#!/usr/bin/env python3
"""test262 progression reconstructed from git history, without running the suite.

    python3 scripts/test262_history.py [--rev main] > test262_history.json

Sources, in date order:
  progress.md          per-phase tables (Total | Pass | Fail | Skip) and the
                       "Last Updated" headline, every revision on REV
  test262_results/latest.json
                       per-phase results committed by the runner
  MEASURED             full-run results quoted in commit messages after the
                       runner stopped writing either file

Until 7663ee8d (2026-08-22) the runner's phases overlapped: Phase 5 swept all of
built-ins/{Object,Array,String,Number,Boolean,Function}, which Phase 3 (Object,
Array) and Phase 6 (the prototypes) also claimed. Per-phase totals therefore
counted those files two or three times. `distinct` removes the duplicates by
dropping the shares of Phase 3 and Phase 6 that sit inside Phase 5, sized from
test262's file counts (DUP_SHARE). Checked at the one point with both numbers,
the 50,002-pass run of 2026-08-17 that 7663ee8d reports as 39,326 distinct
files, the estimate is 39,176 (0.4% low). Headline-only revisions carry just a
summed pass count; their duplicate count is interpolated between the nearest
phase tables. Points after 7663ee8d are exact.
"""
import argparse
import json
import re
import subprocess

# File shares of the overlapping phases that Phase 5 also runs:
#   Phase 3: built-ins/Object 3,411 + built-ins/Array 3,082 + Array/length 30
#            (listed twice) of 7,767 files
#   Phase 6: every dir but built-ins/Math, 4,387 of 4,714 files
DUP_SHARE = {'3': 6523 / 7767, '6': 4387 / 4714}

# The runner's own grouping: phase labels 0-8 say "ES5", 11-21 are the ES2015
# syntax and collection phases, 22+ were added from July on.
GROUPS = [
    ('Core + ES5', lambda n: n <= 8),
    ('ES2015 syntax + collections', lambda n: 11 <= n <= 21),
    ('Buffers, Proxy, async iteration, modules', lambda n: n >= 22),
]

# Full-run results quoted in commit messages once the phases were disjoint.
# fail is None where the message gives no failure count.
MEASURED = [
    ('b35071f6', 'phases', {'all': (39326, 0)}),
    ('ed96a53c', 'phases', {'all': (43736, 360)}),
    ('483c3cfd', 'suites', {'language': (21572, 0), 'built-ins': (22640, 0)}),
    ('bb891b43', 'suites', {'language': (22037, 0), 'built-ins': (22648, 0), 'staging': (1000, 166)}),
    ('e3453a81', 'total', {'all': (45720, 145)}),
    ('ddf6687e', 'suites', {'language': (23392, 0), 'built-ins': (22835, 2), 'staging': (1137, 199)}),
    ('e5a686c6', 'total', {'all': (47370, 195)}),
    ('409d0b95', 'total', {'all': (48331, 171)}),
    ('ff11172d', 'suites', {'language': (23454, 0), 'built-ins': (22903, 0), 'annexB': (896, 0),
                            'staging': (1255, 76)}),
]

# Changes to what the suite counts, for chart annotations.
EVENTS = [
    ('2026-06-18', 'skip patterns corrected'),
    ('2026-07-07', 'targeted subset defined (plan 040)'),
    ('2026-07-22', 'deferred features brought into scope'),
    ('2026-08-16', 'zero failures'),
    ('2026-08-22', 'phases made disjoint'),
    ('2026-08-28', 'Temporal in scope'),
    ('2026-09-02', 'test262 suites replace phases; staging runs'),
    ('2026-09-12', 'sloppy mode and annexB run'),
]

ROW = re.compile(r'^\|\s*(?:\*\*)?(?:Phase\s+)?(\d+(?:-\d+)?)\s*:[^|]*\|\s*~?([\d,]+)\s*\|'
                 r'\s*~?([\d,]+)\s*\|\s*~?([\d,]+)\s*\|\s*~?([\d,]+)\s*\|')
HEADLINE = re.compile(r'^\*\*Last Updated:?\*\*.*?\*{0,2}([\d,]{5,})(?:[-–][\d,]+)?\+? pass', re.M)


def num(s):
    return int(s.replace(',', ''))


def git(repo, *args):
    return subprocess.run(['git', '-C', repo, *args], capture_output=True, text=True, check=True).stdout


def blobs(repo, specs):
    """Contents of each rev:path in specs, in one git process."""
    p = subprocess.run(['git', '-C', repo, 'cat-file', '--batch'], input=('\n'.join(specs) + '\n').encode(),
                       capture_output=True, check=True).stdout
    out, i = [], 0
    for _ in specs:
        header_end = p.index(b'\n', i)
        header = p[i:header_end].split()
        if header[-1] == b'missing':
            out.append(None)
            i = header_end + 1
            continue
        size = int(header[2])
        out.append(p[header_end + 1:header_end + 1 + size].decode('utf-8', 'replace'))
        i = header_end + 1 + size + 1
    return out


def phase_table(text):
    phases, started = {}, False
    for line in text.splitlines():
        m = ROW.match(line)
        if m:
            started = True
            key = m.group(1)
            if key in phases:
                break
            phases[key] = {'total': num(m.group(2)), 'pass': num(m.group(3)),
                           'fail': num(m.group(4)), 'skip': num(m.group(5))}
        elif started and not line.startswith('|'):
            break
    return phases


def phase_number(key):
    return int(key.split('-')[0])


def summarize(phases):
    """Summed, duplicate and per-group counts for one per-phase snapshot."""
    def dup(field):
        return sum(DUP_SHARE[k] * field(phases[k]) for k in DUP_SHARE if k in phases)

    passing = lambda p: p['pass']
    in_scope = lambda p: p['total'] - p['skip']
    groups = {}
    for name, member in GROUPS:
        ks = [k for k in phases if member(phase_number(k))]
        if ks:
            sub = {k: phases[k] for k in ks}
            p = sum(passing(v) for v in sub.values())
            s = sum(in_scope(v) for v in sub.values())
            if name == 'Core + ES5':
                p -= dup(passing)
                s -= dup(in_scope)
            groups[name] = [round(p), round(s)]
    return {
        'reported': sum(passing(p) for p in phases.values()),
        'dup': dup(passing),
        'distinct': round(sum(passing(p) for p in phases.values()) - dup(passing)),
        'in_scope': round(sum(in_scope(p) for p in phases.values()) - dup(in_scope)),
        'groups': groups,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--repo', default='.')
    ap.add_argument('--rev', default='main')
    args = ap.parse_args()

    revs = []
    for path in ('progress.md', 'test262_results/latest.json'):
        for line in git(args.repo, 'log', args.rev, '--format=%h %aI', '--', path).splitlines():
            sha, date = line.split()
            revs.append((date, sha, path))
    revs.sort()
    texts = blobs(args.repo, [f'{sha}:{path}' for _, sha, path in revs])

    points, last_core = [], None
    for (date, sha, path), text in zip(revs, texts):
        if not text:
            continue
        if path == 'progress.md':
            phases = phase_table(text)
        else:
            data = json.loads(text)
            phases = {}
            for p in data.get('phases', []):
                m = re.match(r'Phase (\d+(?:-\d+)?)', p.get('name') or p.get('label', ''))
                if m:
                    phases[m.group(1)] = {k: p[k] for k in ('total', 'pass', 'fail', 'skip')}
        if len(phases) >= 10 and {'3', '5', '6'} <= set(phases):
            # A table that lost its Phase 0-1 row borrows the previous one.
            core = phases.get('0-1') or phases.get('0')
            if core:
                last_core = core
            elif last_core:
                phases['0-1'] = dict(last_core, carried=True)
            points.append({'date': date, 'sha': sha, 'source': path, 'kind': 'phases',
                           **summarize(phases)})
        elif path == 'progress.md':
            m = HEADLINE.search(text)
            if m:
                points.append({'date': date, 'sha': sha, 'source': path, 'kind': 'headline',
                               'reported': num(m.group(1))})

    # Headline points: subtract a duplicate count interpolated in time between
    # the phase snapshots around them.
    tables = [p for p in points if p['kind'] == 'phases']
    for p in points:
        if p['kind'] != 'headline':
            continue
        before = [t for t in tables if t['date'] <= p['date']]
        after = [t for t in tables if t['date'] > p['date']]
        if not before:
            p['kind'] = 'dropped'
            continue
        a = before[-1]
        b = after[0] if after else a
        span = (iso_days(b['date']) - iso_days(a['date'])) or 1
        f = (iso_days(p['date']) - iso_days(a['date'])) / span
        p['dup'] = a['dup'] + f * (b['dup'] - a['dup'])
        p['distinct'] = round(p['reported'] - p['dup'])
    points = [p for p in points if p['kind'] != 'dropped']
    for p in points:
        p.pop('dup', None)
        p['exact'] = False

    for sha, kind, counts in MEASURED:
        date = git(args.repo, 'show', '-s', '--format=%aI', sha).strip()
        point = {'date': date, 'sha': sha, 'source': 'commit message', 'kind': kind, 'exact': True}
        if kind == 'suites':
            point['suites'] = {k: list(v) for k, v in counts.items()}
            point['distinct'] = sum(v[0] for v in counts.values())
            if all(v[1] is not None for v in counts.values()):
                point['in_scope'] = sum(v[0] + v[1] for v in counts.values())
        else:
            passing, fail = counts['all']
            point['distinct'] = passing
            point['in_scope'] = passing + fail
        points.append(point)

    points.sort(key=lambda p: p['date'])
    json.dump({'points': points, 'events': [{'date': d, 'label': l} for d, l in EVENTS],
               'dup_check': {'reported': 50002, 'measured': 39326}}, fp=__import__('sys').stdout,
              separators=(',', ':'))


def iso_days(date):
    import datetime
    return datetime.datetime.fromisoformat(date).timestamp() / 86400


if __name__ == '__main__':
    main()
