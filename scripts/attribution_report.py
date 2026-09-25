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
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agent_metrics import model_name  # noqa: E402

HARNESSES = ['Claude Code', 'Crush', 'opencode', 'opencode or pi', 'Codex', 'Other', 'Unattributed']
OTHER = {'pi', 'Shelley'}
# The commits-by-model bars show every model with more commits than this;
# smaller ones are listed by name under the chart.
BAR_MIN = 15
# Models charted as their own series, grouped by vendor in stacking order.
# Each group takes one categorical color slot (the template's --mN), and its
# models are shaded light to dark, oldest first. Any other model folds into
# "Other models" and is listed by name under the charts.
GROUPS = [
    ('Claude Opus', ['Claude Opus 4.6 / 4.7', 'Claude Opus 4.8', 'Claude Opus 5', 'Claude Opus 5.5']),
    ('Claude Sonnet / Haiku', ['Claude Sonnet 4.6 / Haiku 4.5', 'Claude Sonnet 5']),
    ('Claude Fable', ['Claude Fable 5']),
    ('MiMo', ['MiMo V2 Pro', 'MiMo V2.5', 'MiMo V2.5 Pro', 'MiMo V2.6']),
    ('DeepSeek', ['DeepSeek V4 Flash', 'DeepSeek V4 Pro', 'DeepSeek V4.1']),
    ('MiniMax', ['MiniMax M3']),
    ('Not recorded', ['Not recorded']),
    ('Other models', ['Other models']),
]
MODELS = [m for _, ms in GROUPS for m in ms]

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


def series_of(name):
    return name if name in MODELS else 'Other models'


def tokens(metrics, attrib, weeks, index, claude_prompts, claude_commits, others):
    """Weekly tokens per charted model: measured, Crush estimated, and the
    .attrib snapshot for Claude Code in July. Adds each folded model's tokens
    to `others`."""
    zero = lambda: {m: [0] * len(weeks) for m in MODELS}
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
        total[series_of(name)][w] += t
        output[series_of(name)][w] += o
        if series_of(name) == 'Other models':
            others[name]['tokens'] += t

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
        models = {m['model']: m for m in json.load(open(os.path.join(attrib, 'token_totals.json')))['by_model']
                  if 'claude-code' in m['harnesses']}
        for wk, counts in weekly.items():
            for model, n in counts.items():
                m = models.get(model)
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
    written = {m: [0] * len(weeks) for m in MODELS}
    surviving = {m: [0] * len(weeks) for m in MODELS}
    others = collections.defaultdict(collections.Counter)
    claude_commits = [collections.Counter() for _ in weeks]
    commit_count = collections.Counter(c['name'] for c in commits)
    bar_of = lambda name: name if name in MODELS or commit_count[name] > BAR_MIN else 'Other models'
    claude_prompts = collections.defaultdict(list)

    for c in commits:
        h = bucket(c['harness'])
        commits_weekly[h][index[week_of(c['at'])]] += 1
        totals[h]['commits'] += 1
        totals[h][c['method']] += 1
        m = series_of(c['name'])
        by_model[bar_of(c['name'])][h] += 1
        if h == 'Claude Code' and c['name'] != 'Not recorded':
            claude_commits[index[week_of(c['at'])]][c['name']] += 1
        months[month_of(c['at'])]['commits'] += 1
        written[m][index[week_of(c['at'])]] += c.get('added', 0)
        surviving[m][index[week_of(c['at'])]] += c.get('surviving', 0)
        if m == 'Other models':
            others[c['name']]['commits'] += 1
            others[c['name']]['written'] += c.get('added', 0)
            others[c['name']]['surviving'] += c.get('surviving', 0)
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

    token_weekly = tokens(metrics, attrib, weeks, index, claude_prompts, claude_commits, others)
    # Bars in chart order; models charted only as bars go before the
    # catch-all rows, largest first.
    extra = sorted((n for n in by_model if n not in MODELS), key=lambda n: -sum(by_model[n].values()))
    bar_order = [m for m in MODELS if m not in ('Not recorded', 'Other models')] + extra + ['Not recorded', 'Other models']
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
        'model_groups': GROUPS,
        'written': written,
        'surviving': surviving,
        'others': sorted(({'name': n, **{k: round(v) for k, v in c.items()}} for n, c in others.items()),
                         key=lambda o: o['name'].lower()),
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
