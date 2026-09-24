#!/usr/bin/env python3
"""Build the visual attribution report from the metrics and test262 JSON.

    python3 scripts/agent_metrics.py --json out/agent_metrics.json --blame main
    python3 scripts/test262_history.py > out/test262_history.json
    python3 scripts/attribution_report.py out/agent_metrics.json out/test262_history.json \\
        > out/attribution_report.html

The page template is scripts/attribution_report.html; this script aggregates
the per-commit and per-prompt records into weekly and per-harness series and
substitutes them for the template's /*DATA*/ marker.
"""
import collections
import datetime
import json
import os
import sys

HARNESSES = ['Claude Code', 'Crush', 'opencode', 'opencode or pi', 'Codex', 'Other', 'Unattributed']
OTHER = {'pi', 'Shelley'}

# Figures from the 2026-07-31 snapshot in .attrib/ (token_totals.json,
# line_totals.json, loops.json). Claude Code transcripts from before
# 2026-06-30 were already gone then, and most of the rest since, so these
# cannot be recomputed.
JULY_SNAPSHOT = {
    'date': '2026-07-31',
    'tokens_out': 37236301,
    'tokens_fresh_in': 340947259,
    'tokens_cache_in': 14162608837,
    'cost_usd_known': 803.53,
    'lines_written': 227873,
    'lines_surviving': 114169,
    'loop_ticks': 399,
    'turns': 4466,
}

MILESTONES = [
    ('2026-05-22', 'first commit'),
    ('2026-07-07', 'plan 040: target 100% of the subset'),
    ('2026-08-16', 'test262 zero failures'),
    ('2026-08-18', 'renamed duktape-c3 → boomkat'),
    ('2026-09-12', 'sloppy mode + annexB'),
]


def bucket(name):
    return 'Other' if name in OTHER else name


def week_of(ts):
    d = datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).date()
    return (d - datetime.timedelta(days=d.weekday())).isoformat()


def month_of(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime('%Y-%m')


def build(metrics, t262):
    commits, prompts = metrics['commits'], metrics['prompts']
    first = min(c['at'] for c in commits)
    last = max(max(c['at'] for c in commits), max(p['ts'] for p in prompts))
    weeks, d = [], datetime.date.fromisoformat(week_of(first))
    while d.isoformat() <= week_of(last):
        weeks.append(d.isoformat())
        d += datetime.timedelta(days=7)
    index = {w: i for i, w in enumerate(weeks)}

    def series():
        return {h: [0] * len(weeks) for h in HARNESSES}

    commits_weekly, prompts_weekly = series(), series()
    input_weekly = {k: [0] * len(weeks) for k in ('long', 'short', 'repeated')}
    totals = {h: collections.Counter() for h in HARNESSES}
    families = collections.defaultdict(collections.Counter)
    months = collections.defaultdict(collections.Counter)

    for c in commits:
        h = bucket(c['harness'])
        commits_weekly[h][index[week_of(c['at'])]] += 1
        totals[h]['commits'] += 1
        totals[h][c['method']] += 1
        families[c['family']][h] += 1
        months[month_of(c['at'])]['commits'] += 1
    for p in prompts:
        h = bucket(p['harness'])
        w = index.get(week_of(p['ts']))
        if w is None:
            continue
        kind = 'repeated' if p['repeated'] else 'long' if p['words'] > 10 else 'short'
        prompts_weekly[h][w] += 1
        input_weekly[kind][w] += 1
        totals[h]['prompts'] += 1
        totals[h][kind] += 1
        months[month_of(p['ts'])][kind] += 1
    for row in metrics.get('surviving', {}).get('lines', []):
        totals[bucket(row['harness'])]['lines'] += row['lines']

    seen, points = set(), []
    for p in t262['points']:
        if p['sha'] in seen or p.get('distinct') is None:
            continue
        seen.add(p['sha'])
        points.append({k: p[k] for k in ('date', 'sha', 'kind', 'exact', 'distinct', 'in_scope',
                                          'groups', 'suites', 'reported') if k in p})

    return {
        'generated': metrics['generated'],
        'harnesses': HARNESSES,
        'weeks': weeks,
        'commits_weekly': commits_weekly,
        'prompts_weekly': prompts_weekly,
        'input_weekly': input_weekly,
        'totals': {h: dict(c) for h, c in totals.items()},
        'families': sorted(([f, dict(c)] for f, c in families.items()),
                           key=lambda x: -sum(x[1].values())),
        'months': [[m, dict(c)] for m, c in sorted(months.items())],
        'calibration': metrics['calibration'],
        'surviving': {k: v for k, v in metrics.get('surviving', {}).items() if k != 'lines'},
        'test262': {'points': points, 'events': t262['events'], 'dup_check': t262['dup_check']},
        'milestones': [{'date': d, 'label': l} for d, l in MILESTONES],
        'july': JULY_SNAPSHOT,
    }


def main():
    metrics = json.load(open(sys.argv[1]))
    t262 = json.load(open(sys.argv[2]))
    template = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'attribution_report.html')).read()
    data = json.dumps(build(metrics, t262), separators=(',', ':'))
    sys.stdout.write(template.replace('/*DATA*/null', data))


if __name__ == '__main__':
    main()
