#!/usr/bin/env python3
"""Build the visual attribution report from the metrics and test262 JSON.

    python3 scripts/agent_metrics.py --json out/agent_metrics.json --blame main
    python3 scripts/test262_history.py > out/test262_history.json
    python3 scripts/attribution_report.py out/agent_metrics.json out/test262_history.json \\
        [--attrib .attrib] > out/attribution_report.html

The page template is scripts/attribution_report.html; this script aggregates
the per-commit, per-prompt and per-day token records into weekly series and
substitutes them for the template's /*DATA*/ marker.

Token counts have two holes that the harness logs cannot fill:
  Crush        keeps no per-message token counts. Its weekly tokens are
               estimated as its message count per model family times
               opencode's measured tokens per message for that family, since
               both ran the same models through the same providers.
  Claude Code  deletes transcripts after 30 days by default. The .attrib
               snapshot (--attrib) recorded per-model token totals and weekly
               message counts for 2026-06-30..07-31; weeks outside that and
               outside the surviving transcripts are marked as not recorded.
"""
import argparse
import collections
import datetime
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agent_metrics import model_family  # noqa: E402

HARNESSES = ['Claude Code', 'Crush', 'opencode', 'opencode or pi', 'Codex', 'Other', 'Unattributed']
OTHER = {'pi', 'Shelley'}
# Model families for the line and token charts, in stacking order. Families
# with few commits fold into "Other models".
FAMILIES = ['Claude Opus 5.x', 'Claude Opus 4.x', 'Claude Fable 5', 'Claude Sonnet / Haiku',
            'DeepSeek V4', 'Xiaomi MiMo', 'MiniMax M3', 'Other models', 'Not recorded']

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


def family(f):
    return f if f in FAMILIES else 'Other models'


def tokens(metrics, attrib, weeks, index, claude_prompts):
    """Weekly tokens per model family: measured, Crush estimated, and the
    .attrib snapshot for Claude Code in July."""
    zero = lambda: {f: [0] * len(weeks) for f in FAMILIES}
    total, output = zero(), zero()
    crush_total, crush_output = [0] * len(weeks), [0] * len(weeks)
    per_msg = collections.defaultdict(lambda: [0, 0, 0])
    covered = set()
    for r in metrics['tokens']:
        if r['harness'] == 'opencode':
            m = per_msg[family(r['family'])]
            m[0] += r['messages']
            m[1] += r['total']
            m[2] += r['output']
        if r['harness'] == 'Claude Code':
            covered.add(r['day'])
    overall = [sum(v[i] for v in per_msg.values()) for i in range(3)]
    for r in metrics['tokens']:
        w = index.get(week_of_day(r['day']))
        if w is None:
            continue
        f = family(r['family'])
        if r['harness'] == 'Crush':
            m = per_msg[f] if per_msg[f][0] >= 200 else overall
            t, o = r['messages'] * m[1] / m[0], r['messages'] * m[2] / m[0]
            crush_total[w] += t
            crush_output[w] += o
        else:
            t, o = r['total'], r['output']
        total[f][w] += t
        output[f][w] += o

    snapshot_weeks = set()
    if attrib:
        weekly = json.load(open(os.path.join(attrib, 'activity_weekly.json')))['by_week']
        models = {m['model']: m for m in json.load(open(os.path.join(attrib, 'token_totals.json')))['by_model']
                  if 'claude-code' in m['harnesses']}
        for wk, counts in weekly.items():
            for model, n in counts.items():
                m = models.get(model)
                if not m or wk not in index or not m['messages']:
                    continue
                f = family(model_family(model))
                all_tokens = m['tokens_out'] + m['tokens_fresh_in'] + m['tokens_cache_in']
                total[f][index[wk]] += n * all_tokens / m['messages']
                output[f][index[wk]] += n * m['tokens_out'] / m['messages']
                snapshot_weeks.add(wk)

    # A week is missing Claude Code tokens when most of its Claude Code prompts
    # fall on days with no transcript and no snapshot covers it.
    gaps = []
    for w in weeks:
        days = claude_prompts.get(w, [])
        if w in snapshot_weeks or len(days) < 10:
            continue
        if sum(d in covered for d in days) < len(days) / 2:
            gaps.append(w)
    rnd = lambda d: {k: [round(x) for x in v] for k, v in d.items()}
    return {'total': rnd(total), 'output': rnd(output),
            'crush_total': [round(x) for x in crush_total], 'crush_output': [round(x) for x in crush_output],
            'claude_gaps': gaps}


def week_of_day(day):
    d = datetime.date.fromisoformat(day)
    return (d - datetime.timedelta(days=d.weekday())).isoformat()


def build(metrics, t262, attrib=None):
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
    written = {f: [0] * len(weeks) for f in FAMILIES}
    surviving = {f: [0] * len(weeks) for f in FAMILIES}
    claude_prompts = collections.defaultdict(list)

    for c in commits:
        h = bucket(c['harness'])
        commits_weekly[h][index[week_of(c['at'])]] += 1
        totals[h]['commits'] += 1
        totals[h][c['method']] += 1
        families[c['family']][h] += 1
        months[month_of(c['at'])]['commits'] += 1
        written[family(c['family'])][index[week_of(c['at'])]] += c.get('added', 0)
        surviving[family(c['family'])][index[week_of(c['at'])]] += c.get('surviving', 0)
        totals[h]['lines'] += c.get('surviving', 0)
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
        if h == 'Claude Code':
            claude_prompts[weeks[w]].append(
                datetime.datetime.fromtimestamp(p['ts'], datetime.timezone.utc).date().isoformat())

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
        'model_order': FAMILIES,
        'written': written,
        'surviving': surviving,
        'lines': metrics.get('lines', {}),
        'tokens': tokens(metrics, attrib, weeks, index, claude_prompts),
        'test262': {'points': points, 'events': t262['events'], 'dup_check': t262['dup_check']},
        'milestones': [{'date': d, 'label': l} for d, l in MILESTONES],
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('metrics')
    ap.add_argument('test262')
    ap.add_argument('--attrib', help='the .attrib snapshot directory, for Claude Code tokens in July')
    args = ap.parse_args()
    metrics = json.load(open(args.metrics))
    t262 = json.load(open(args.test262))
    template = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'attribution_report.html')).read()
    data = json.dumps(build(metrics, t262, args.attrib), separators=(',', ':'))
    sys.stdout.write(template.replace('/*DATA*/null', data))


if __name__ == '__main__':
    main()
