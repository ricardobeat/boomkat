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
               estimated as its message count per model times opencode's
               measured tokens per message for that model (or opencode's
               overall average below 200 messages), since both ran the same
               models through the same providers.
  Claude Code  deletes transcripts after 30 days by default. The .attrib
               snapshot (--attrib) recorded per-model token totals and weekly
               message counts for 2026-06-30..07-31. Its prompt history kept
               every prompt, so days with neither a transcript nor the
               snapshot are estimated as their prompt count times the tokens
               per prompt measured over all covered days, split across the
               models of that week's Claude Code commits.
"""
import argparse
import collections
import datetime
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agent_metrics import model_name  # noqa: E402

HARNESSES = ['Claude Code', 'Crush', 'opencode', 'opencode or pi', 'Codex', 'Other', 'Unattributed']
OTHER = {'pi', 'Shelley'}
# The commits-by-model bars show every model with more commits than this;
# smaller ones are listed by name under the chart.
BAR_MIN = 15
# Model families for the cumulative charts, in stacking order, matched
# against model names from agent_metrics.model_name. Each takes one
# categorical color slot (the template's --mN). Models matching none fold
# into "Other models" and are listed by name under the charts.
FAMILIES = [
    ('Claude Opus 5.x', r'^Claude Opus 5'),
    ('Claude Opus 4.x', r'^Claude Opus 4'),
    ('Claude Fable 5', r'^Claude Fable'),
    ('Claude Sonnet / Haiku', r'^Claude (Sonnet|Haiku)'),
    ('DeepSeek V4', r'^DeepSeek V4'),
    ('Xiaomi MiMo', r'^MiMo'),
    ('MiniMax', r'^MiniMax'),
    ('Other models', None),
    ('Not recorded', r'^Not recorded$'),
]
FAMILY_NAMES = [f for f, _ in FAMILIES]

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


def family(name):
    return next((f for f, pattern in FAMILIES if pattern and re.search(pattern, name)), 'Other models')


def tokens(metrics, attrib, weeks, index, claude_prompts, claude_commits, models):
    """Weekly tokens per model family: measured, Crush estimated, the .attrib
    snapshot for Claude Code in July, and Claude Code estimates where neither
    exists. Adds each model's total to `models`."""
    zero = lambda: {f: [0] * len(weeks) for f in FAMILY_NAMES}
    total, output = zero(), zero()
    crush_total, crush_output = [0] * len(weeks), [0] * len(weeks)
    per_msg = collections.defaultdict(lambda: [0, 0, 0])
    covered = set()
    for r in metrics['tokens']:
        if r['harness'] == 'opencode':
            m = per_msg[r['model']]
            m[0] += r['messages']
            m[1] += r['total']
            m[2] += r['output']
        if r['harness'] == 'Claude Code':
            covered.add(r['day'])
    overall = [sum(v[i] for v in per_msg.values()) for i in range(3)]

    def add(name, w, t, o):
        total[family(name)][w] += t
        output[family(name)][w] += o
        models[name]['tokens'] += t

    for r in metrics['tokens']:
        w = index.get(week_of_day(r['day']))
        if w is None:
            continue
        if r['harness'] == 'Crush':
            m = per_msg[r['model']] if per_msg[r['model']][0] >= 200 else overall
            t, o = r['messages'] * m[1] / m[0], r['messages'] * m[2] / m[0]
            crush_total[w] += t
            crush_output[w] += o
        else:
            t, o = r['total'], r['output']
        add(r['model'], w, t, o)

    snapshot_weeks, snapshot_tokens = set(), [0, 0]
    if attrib:
        weekly = json.load(open(os.path.join(attrib, 'activity_weekly.json')))['by_week']
        snapshot_models = {m['model']: m for m in
                           json.load(open(os.path.join(attrib, 'token_totals.json')))['by_model']
                           if 'claude-code' in m['harnesses']}
        for wk, counts in weekly.items():
            for model, n in counts.items():
                m = snapshot_models.get(model)
                if not m or wk not in index or not m['messages']:
                    continue
                all_tokens = m['tokens_out'] + m['tokens_fresh_in'] + m['tokens_cache_in']
                add(model_name(model), index[wk], n * all_tokens / m['messages'], n * m['tokens_out'] / m['messages'])
                snapshot_tokens[0] += n * all_tokens / m['messages']
                snapshot_tokens[1] += n * m['tokens_out'] / m['messages']
                snapshot_weeks.add(wk)

    # Claude Code days with prompts but neither a transcript nor the snapshot:
    # prompts times the tokens per prompt measured where both exist.
    measured = [0, 0, 0]  # prompts, all tokens, output tokens
    claude = collections.defaultdict(lambda: [0, 0])
    for r in metrics['tokens']:
        if r['harness'] == 'Claude Code':
            claude[r['day']][0] += r['total']
            claude[r['day']][1] += r['output']
    for w in weeks:
        for day in claude_prompts.get(w, []):
            if w in snapshot_weeks or day in covered:
                measured[0] += 1
    measured[1] = sum(t for t, _ in claude.values()) + snapshot_tokens[0]
    measured[2] = sum(o for _, o in claude.values()) + snapshot_tokens[1]
    for i, w in enumerate(weeks):
        missing = sum(1 for day in claude_prompts.get(w, []) if day not in covered and w not in snapshot_weeks)
        if not missing:
            continue
        # Models of the nearest week with attributed Claude Code commits.
        near = min((j for j in range(len(weeks)) if claude_commits[j]), key=lambda j: abs(j - i))
        shares = claude_commits[near]
        n = sum(shares.values())
        for name, k in shares.items():
            add(name, i, missing * measured[1] / measured[0] * k / n, missing * measured[2] / measured[0] * k / n)
    rnd = lambda d: {k: [round(x) for x in v] for k, v in d.items()}
    return {'total': rnd(total), 'output': rnd(output),
            'crush_total': [round(x) for x in crush_total], 'crush_output': [round(x) for x in crush_output]}


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
    by_model = collections.defaultdict(collections.Counter)
    months = collections.defaultdict(collections.Counter)
    written = {f: [0] * len(weeks) for f in FAMILY_NAMES}
    surviving = {f: [0] * len(weeks) for f in FAMILY_NAMES}
    models = collections.defaultdict(collections.Counter)
    claude_commits = [collections.Counter() for _ in weeks]
    commit_count = collections.Counter(c['name'] for c in commits)
    bar_of = lambda name: name if commit_count[name] > BAR_MIN or name == 'Not recorded' else 'Other models'
    claude_prompts = collections.defaultdict(list)

    for c in commits:
        h = bucket(c['harness'])
        commits_weekly[h][index[week_of(c['at'])]] += 1
        totals[h]['commits'] += 1
        totals[h][c['method']] += 1
        f = family(c['name'])
        by_model[bar_of(c['name'])][h] += 1
        if h == 'Claude Code' and c['name'] != 'Not recorded':
            claude_commits[index[week_of(c['at'])]][c['name']] += 1
        months[month_of(c['at'])]['commits'] += 1
        written[f][index[week_of(c['at'])]] += c.get('added', 0)
        surviving[f][index[week_of(c['at'])]] += c.get('surviving', 0)
        models[c['name']]['commits'] += 1
        models[c['name']]['written'] += c.get('added', 0)
        models[c['name']]['surviving'] += c.get('surviving', 0)
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

    token_weekly = tokens(metrics, attrib, weeks, index, claude_prompts, claude_commits, models)
    # Models in family order, then by commits.
    order = lambda n: (FAMILY_NAMES.index(family(n)), -models[n]['commits'], n)
    bar_order = sorted((n for n in by_model if n != 'Other models'), key=order) + ['Other models']
    return {
        'generated': metrics['generated'],
        'harnesses': HARNESSES,
        'weeks': weeks,
        'commits_weekly': commits_weekly,
        'prompts_weekly': prompts_weekly,
        'input_weekly': input_weekly,
        'totals': {h: dict(c) for h, c in totals.items()},
        'by_model': [[m, dict(by_model[m])] for m in bar_order if by_model[m]],
        'bar_min': BAR_MIN,
        'months': [[m, dict(c)] for m, c in sorted(months.items())],
        'families': FAMILY_NAMES,
        'written': written,
        'surviving': surviving,
        'models': [{'name': n, 'family': family(n), **{k: round(v) for k, v in models[n].items()}}
                   for n in sorted(models, key=order)],
        'lines': metrics.get('lines', {}),
        'tokens': token_weekly,
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
