#!/usr/bin/env python3
"""Agent attribution and usage metrics for ATTRIBUTION.md.

Reads every coding-agent harness's local logs (read-only), attributes each
commit to a harness, and prints the tables used in ATTRIBUTION.md:

    python3 scripts/agent_metrics.py [--repo PATH]

Sources, all filtered to sessions whose working directory is this repo under
either of its names (REPO_MARKERS):
  Crush        <repo>/.crush/crush.db
  opencode     ~/.local/share/opencode/opencode.db
  Codex        ~/.codex/sessions/**/*.jsonl
  pi           ~/.pi/agent/sessions/<encoded cwd>/*.jsonl
  Claude Code  ~/.claude/history.jsonl, ~/.claude/projects/<encoded cwd>/**/*.jsonl

Commit attribution, first match wins:
  1. log      a harness logged `[branch sha] subject` from its own git commit
  2. trailer  Assisted-by / Co-Authored-By / "Generated with Crush"
  3. time     the only harness active in the 3 minutes before the author
              timestamp, else the one with the most recent activity in 2 hours
"""
import argparse
import bisect
import collections
import datetime
import glob
import json
import os
import re
import sqlite3
import subprocess

REPO_MARKERS = ('cousas/boomkat', 'cousas/duktape-c3')
HOME = os.path.expanduser('~')

COMMIT_LINE = re.compile(r'\[([^\[\]\n]{1,80}?) ([0-9a-f]{7,40})\] ([^\n]{0,200})')
ACTIVE_WINDOW = 180          # seconds of harness activity before a commit
PROMPT_WINDOW = 2700         # Claude Code prompts only (no transcript)
NEAREST_WINDOW = 7200


def in_repo(path):
    return any(m in (path or '') for m in REPO_MARKERS)


def ro(path, immutable=False):
    uri = f'file:{path}?mode=ro' + ('&immutable=1' if immutable else '')
    return sqlite3.connect(uri, uri=True)


def iso(ts):
    return datetime.datetime.fromisoformat(ts.replace('Z', '+00:00')).timestamp()


def jsonl(path):
    with open(path, errors='ignore') as f:
        for line in f:
            try:
                yield json.loads(line)
            except ValueError:
                continue


class Harness:
    def __init__(self, name):
        self.name = name
        self.commits = []        # (sha prefix, subject, model)
        self.prompts = []        # (unix ts, text)
        self.activity = []       # unix ts of any message
        self.models = []         # (unix ts, model) of assistant messages
        self.tokens = []         # (unix ts, model, all tokens, output tokens) per response
        self.usage = collections.defaultdict(collections.Counter)

    def scan_commits(self, text, model):
        for _branch, sha, subject in COMMIT_LINE.findall(text or ''):
            self.commits.append((sha, subject.strip(), model or '?'))

    def model_at(self, t):
        """The model of the last assistant message at or before t."""
        if not hasattr(self, '_model_ts'):
            self.models.sort()
            self._model_ts = [ts for ts, _ in self.models]
        i = bisect.bisect_right(self._model_ts, t + 30)
        return self.models[i - 1][1] if i else None


# --- harness readers --------------------------------------------------------

def read_crush(repo):
    h = Harness('Crush')
    db = ro(os.path.join(repo, '.crush/crush.db'), immutable=True)
    top = {sid for (sid,) in db.execute(
        'select id from sessions where parent_session_id is null')}
    model = {}
    q = """select session_id, role, provider, model, created_at,
                  case when role = 'user' or (role = 'tool' and parts like '%] %') then parts end
           from messages order by session_id, created_at, rowid"""
    for sid, role, prov, mdl, ts, parts in db.execute(q):
        ts = ts / 1000 if ts > 1e11 else ts
        if role == 'assistant':
            h.activity.append(ts)
            if mdl:
                model[sid] = f'{prov}/{mdl}'
                h.models.append((ts, model[sid]))
                h.usage[f'{prov}/{mdl}']['messages'] += 1
        elif role == 'tool' and parts:
            for p in json.loads(parts):
                if p.get('type') == 'tool_result' and p['data'].get('name') == 'bash':
                    h.scan_commits(p['data'].get('content'), model.get(sid))
        elif role == 'user' and sid in top and parts:
            ps = json.loads(parts)
            if any(p['type'] == 'shell_command' for p in ps):
                continue
            text = '\n'.join(p['data'].get('text', '') for p in ps if p['type'] == 'text')
            if text.strip():
                h.prompts.append((ts, text))
    # Crush keeps only the last turn's token counts per session; cost accumulates.
    h.sessions = db.execute(
        """select strftime('%Y-%m', created_at, 'unixepoch'), count(*),
                  sum(parent_session_id is null), sum(message_count), sum(cost)
           from sessions group by 1""").fetchall()
    return h


def read_opencode():
    h = Harness('opencode')
    db = ro(f'{HOME}/.local/share/opencode/opencode.db')
    projects = [pid for pid, wt in db.execute('select id, worktree from project') if in_repo(wt)]
    marks = ','.join('?' * len(projects))
    where = f's.project_id in ({marks})'
    for mdata, ts in db.execute(
            f'select m.data, m.time_created from message m join session s on s.id = m.session_id where {where}',
            projects):
        h.activity.append(ts / 1000)
        m = json.loads(mdata)
        if m.get('role') != 'assistant':
            continue
        h.models.append((ts / 1000, f"{m.get('providerID')}/{m.get('modelID')}"))
        u, t = h.usage[f"{m.get('providerID')}/{m.get('modelID')}"], m.get('tokens') or {}
        u['messages'] += 1
        u['input'] += t.get('input') or 0
        u['output'] += t.get('output') or 0
        u['cache_read'] += (t.get('cache') or {}).get('read') or 0
        u['cost_micro'] += int(1e6 * (m.get('cost') or 0))
        cache = t.get('cache') or {}
        out = (t.get('output') or 0) + (t.get('reasoning') or 0)
        h.tokens.append((ts / 1000, f"{m.get('providerID')}/{m.get('modelID')}",
                         (t.get('input') or 0) + out + (cache.get('read') or 0) + (cache.get('write') or 0), out))
    q = f"""select p.data, m.data, m.id, m.time_created, s.parent_id is null
            from part p join message m on m.id = p.message_id join session s on s.id = p.session_id
            where {where}"""
    texts = collections.defaultdict(list)
    for pdata, mdata, mid, ts, top in db.execute(q, projects):
        p = json.loads(pdata)
        if p.get('type') == 'tool' and p.get('tool') == 'bash':
            m = json.loads(mdata)
            h.scan_commits((p.get('state') or {}).get('output'), f"{m.get('providerID')}/{m.get('modelID')}")
        elif top and p.get('type') == 'text' and not p.get('synthetic') and json.loads(mdata).get('role') == 'user':
            texts[(ts, mid)].append(p.get('text', ''))
    h.prompts = [(ts / 1000, '\n'.join(t)) for (ts, _), t in texts.items() if '\n'.join(t).strip()]
    h.sessions = db.execute(f'select count(*), sum(parent_id is null) from session s where {where}',
                            projects).fetchone()
    return h


def read_codex():
    h = Harness('Codex')
    for path in glob.glob(f'{HOME}/.codex/sessions/**/*.jsonl', recursive=True):
        model, top, ok = '?', False, None
        for d in jsonl(path):
            kind, p = d.get('type'), d.get('payload') or {}
            if kind == 'session_meta':
                ok = in_repo(p.get('cwd'))
                top = not isinstance(p.get('source'), dict)
                if not ok:
                    break
                continue
            if kind == 'turn_context':
                model = p.get('model', model)
            elif kind == 'token_usage_record':
                # input_tokens includes the cached ones; total = input + output.
                t = p['usage']
                h.tokens.append((iso(d['timestamp']), model, t.get('total_tokens', 0), t.get('output_tokens', 0)))
                u = h.usage[model]
                for k, v in p['usage'].items():
                    if isinstance(v, int):
                        u[k] += v
            elif kind == 'response_item':
                h.activity.append(iso(d['timestamp']))
                if p.get('role') == 'assistant':
                    h.models.append((iso(d['timestamp']), model))
                if p.get('type') in ('function_call_output', 'custom_tool_call_output'):
                    out = p.get('output')
                    h.scan_commits(out if isinstance(out, str) else json.dumps(out), model)
                elif top and p.get('type') == 'message' and p.get('role') == 'user':
                    text = '\n'.join(c.get('text', '') for c in p.get('content', [])
                                     if c.get('type') == 'input_text'
                                     and not c.get('text', '').lstrip().startswith(('<', '# AGENTS.md')))
                    if text.strip():
                        h.prompts.append((iso(d['timestamp']), text))
        if ok:
            h.usage[model]['rollouts'] += 1
    return h


def read_pi():
    h = Harness('pi')
    model = '?'
    for path in glob.glob(f'{HOME}/.pi/agent/sessions/*/*.jsonl'):
        # pi encodes the cwd in the directory name with '/' replaced by '-'.
        if not any(m.replace('/', '-') in os.path.dirname(path) for m in REPO_MARKERS):
            continue
        for d in jsonl(path):
            if d.get('type') != 'message':
                continue
            m, ts = d['message'], iso(d['timestamp'])
            h.activity.append(ts)
            content = [c for c in m.get('content', []) if isinstance(c, dict)]
            if m.get('role') == 'assistant':
                model = f"{m.get('provider')}/{m.get('model')}"
                h.models.append((ts, model))
                u, t = h.usage[model], m.get('usage') or {}
                u['messages'] += 1
                u['input'] += t.get('input', 0)
                u['output'] += t.get('output', 0)
                u['cache_read'] += t.get('cacheRead', 0)
                u['cost_micro'] += int(1e6 * (t.get('cost') or {}).get('total', 0))
                h.tokens.append((ts, model, t.get('totalTokens', 0), t.get('output', 0)))
            elif m.get('role') == 'user':
                text = '\n'.join(c.get('text', '') for c in content if c.get('type') == 'text')
                if text.strip():
                    h.prompts.append((ts, text))
            elif m.get('role') == 'toolResult':
                h.scan_commits('\n'.join(c.get('text', '') for c in content), model)
    return h


def read_claude():
    h = Harness('Claude Code')
    h.prompt_times = []
    sessions = set()
    for d in jsonl(f'{HOME}/.claude/history.jsonl'):
        if in_repo(d.get('project')):
            ts = d['timestamp'] / 1000
            h.prompt_times.append(ts)
            sessions.add(d.get('sessionId'))
            h.prompts.append((ts, d.get('display', '')))
    h.sessions = len(sessions)
    last = {}
    for path in glob.glob(f'{HOME}/.claude/projects/*/**/*.jsonl', recursive=True):
        model = '?'
        for d in jsonl(path):
            if not in_repo(d.get('cwd')) or d.get('type') not in ('assistant', 'user'):
                continue
            h.activity.append(iso(d['timestamp']))
            msg = d.get('message') or {}
            if d['type'] == 'assistant':
                model = msg.get('model', model)
                h.models.append((iso(d['timestamp']), model))
                # Streaming writes several lines per message id; the last has final usage.
                last[msg.get('id') or d.get('uuid')] = (iso(d['timestamp']), model, msg.get('usage') or {})
            elif isinstance(msg.get('content'), list):
                for b in msg['content']:
                    if isinstance(b, dict) and b.get('type') == 'tool_result':
                        c = b.get('content')
                        text = c if isinstance(c, str) else '\n'.join(
                            x.get('text', '') for x in c or [] if isinstance(x, dict))
                        h.scan_commits(text, model)
    keys = ('input_tokens', 'output_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens')
    for ts, model, u in last.values():
        c = h.usage[model]
        c['messages'] += 1
        for k in keys:
            c[k] += u.get(k) or 0
        h.tokens.append((ts, model, sum(u.get(k) or 0 for k in keys), u.get('output_tokens') or 0))
    return h


# --- commit attribution -----------------------------------------------------

def trailer(body):
    ab = re.findall(r'^Assisted-by:\s*(.+)$', body, re.M | re.I)
    co = re.findall(r'^Co-Authored-By:\s*(.+)$', body, re.M | re.I)
    if ab:
        return ab[0].strip()
    if co:
        return re.sub(r'\s*<.*', '', co[0]).strip()
    if 'Generated with Crush' in body:
        return 'Crush'
    return None


def harness_of_trailer(t):
    if t.startswith('Crush'):
        return 'Crush'
    if t.startswith('Claude'):
        return 'Claude Code'
    if t.startswith('Shelley'):
        return 'Shelley'
    if t.startswith('GPT'):
        return 'Codex'
    if re.match(r'(Mimo|Deepseek|deepseek|Kimi)', t):
        return 'opencode or pi'   # model-only co-author lines
    return None


def attribute(repo, harnesses):
    fmt = '%H%x1f%an%x1f%at%x1f%s%x1f%B%x1e'
    out = subprocess.run(['git', '-C', repo, 'log', '--branches', '--tags', '--remotes',
                          '--no-merges', f'--format={fmt}'],
                         capture_output=True, text=True, check=True).stdout
    commits = {}
    for rec in out.split('\x1e'):
        rec = rec.lstrip('\n')
        if rec:
            sha, author, at, subject, body = rec.split('\x1f', 4)
            commits[sha] = (author, int(at), subject, body)
    shas = sorted(commits)

    logged, stale = {}, 0
    for h in harnesses:
        for prefix, subject, model in h.commits:
            i = bisect.bisect_left(shas, prefix)
            hits = [s for s in shas[i:i + 2] if s.startswith(prefix)]
            if len(hits) == 1 and commits[hits[0]][2][:30] == subject[:30]:
                logged[hits[0]] = (h.name, model)
            else:
                stale += 1

    # Rebased and cherry-picked copies keep author, author date and subject.
    groups = collections.defaultdict(list)
    for sha, (author, at, subject, body) in commits.items():
        groups[(author, at, subject)].append(sha)

    claude = next(h for h in harnesses if h.name == 'Claude Code')
    timelines = [(h.name, sorted(h.activity), ACTIVE_WINDOW) for h in harnesses]
    timelines.append(('Claude Code', sorted(claude.prompt_times), PROMPT_WINDOW))

    def by_time(t):
        active, recent = set(), {}
        for name, ts, window in timelines:
            i = bisect.bisect_right(ts, t + 30)
            if not i:
                continue
            gap = t - ts[i - 1]
            if gap <= window:
                active.add(name)
            if gap <= NEAREST_WINDOW and gap < recent.get(name, NEAREST_WINDOW + 1):
                recent[name] = gap
        if len(active) == 1:
            return active.pop()
        return min(recent, key=recent.get) if recent else None

    by_name = {h.name: h for h in harnesses}
    table = collections.Counter()
    models = collections.defaultdict(collections.Counter)
    calibration = collections.Counter()
    records = []
    for key, members in groups.items():
        at = key[1]
        log = next((logged[s] for s in members if s in logged), None)
        t = next((trailer(commits[s][3]) for s in members if trailer(commits[s][3])), None)
        if log:
            name, method, model = log[0], 'log', log[1].split('/')[-1]
            models[name][model] += 1
            calibration[by_time(at) == name] += 1
        elif t and harness_of_trailer(t):
            name, method = harness_of_trailer(t), 'trailer'
            model = re.sub(r'^Crush:?', '', t) or '(not recorded)'
            models[name][model] += 1
        else:
            name, method = by_time(at) or 'Unattributed', 'time'
            # The model is inferred like the harness: the one that harness was
            # running at commit time. Not counted in the `models` table.
            model = name in by_name and by_name[name].model_at(at)
            model = model.split('/')[-1] if model else '(not recorded)'
        table[(name, method)] += 1
        records.append({'at': at, 'harness': name, 'method': method, 'model': model,
                        'family': model_family(model), 'shas': members})
    return {'commits': len(commits), 'distinct': len(groups), 'logged_lines':
            sum(len(h.commits) for h in harnesses), 'stale': stale,
            'table': table, 'models': models, 'calibration': calibration,
            'records': records}


FAMILIES = [
    (r'opus[- ]5', 'Claude Opus 5.x'),
    (r'opus[- ]4', 'Claude Opus 4.x'),
    (r'fable', 'Claude Fable 5'),
    (r'sonnet|haiku', 'Claude Sonnet / Haiku'),
    (r'deepseek', 'DeepSeek V4'),
    (r'minimax', 'MiniMax M3'),
    (r'mimo', 'Xiaomi MiMo'),
    (r'kimi|^k3', 'Kimi'),
    (r'glm', 'GLM'),
    (r'gpt|astra|sol', 'GPT (OpenAI)'),
]


def model_family(model):
    for pattern, family in FAMILIES:
        if re.search(pattern, model, re.I):
            return family
    return 'Not recorded' if model in ('(not recorded)', 'Shelley', '?', '<synthetic>') else 'Other'


# --- surviving lines --------------------------------------------------------

SOURCE_GLOBS = ('*.c3', '*.c', '*.h', '*.sh', '*.py')
VENDORED = ('libregexp/', 'vendor/')
GENERATED = ('*_generated.c3',)
# Whole-tree mechanical rewrites. Blame looks through them to the commit that
# wrote each line, and their lines do not count as written.
MECHANICAL = (
    '4481e0f15e23470e305cbb7f6bd3a2697623d3dd',  # style: replace /// with // in src comments
)


def blame_file(repo, rev, path):
    ignore = [a for sha in MECHANICAL for a in ('--ignore-rev', sha)]
    out = subprocess.run(['git', '-C', repo, 'blame', '--porcelain', '-w', '-M', '-C', *ignore, rev, '--', path],
                         capture_output=True, text=True, errors='replace').stdout
    counts = collections.Counter()
    for line in out.split('\n'):
        # Header lines are "<sha> <orig line> <final line> [<group size>]".
        parts = line.split(' ')
        if len(parts) >= 3 and len(parts[0]) == 40 and parts[1].isdigit():
            counts[parts[0]] += 1
    return counts


def line_counts(repo, rev, records):
    """Source lines each commit record added on rev, and how many survive at rev.

    A line counts as added unless the same commit also removes an identical
    line (ignoring indentation), so splitting a file or moving a function is
    not counted as new code. Survivors come from git blame, which credits each
    line to the last commit that touched it.
    """
    from concurrent.futures import ThreadPoolExecutor
    import fnmatch

    def source(f):
        name = os.path.basename(f)
        return (any(fnmatch.fnmatch(name, g) for g in SOURCE_GLOBS)
                and not any(fnmatch.fnmatch(name, g) for g in GENERATED)
                and not f.startswith(VENDORED))

    owner = {sha: i for i, r in enumerate(records) for sha in r['shas']}
    added, surviving = collections.Counter(), collections.Counter()
    proc = subprocess.Popen(['git', '-C', repo, 'log', rev, '--no-merges', '-M', '-p', '-U0',
                             '--no-color', '--format=@%H'],
                            stdout=subprocess.PIPE, text=True, errors='replace')
    i, keep, plus, minus = None, False, collections.Counter(), collections.Counter()

    def flush():
        if i is not None:
            added[i] += sum(n - min(n, minus[line]) for line, n in plus.items())

    for line in proc.stdout:
        if line.startswith('@') and not line.startswith('@@'):
            flush()
            sha = line[1:].strip()
            i = None if sha in MECHANICAL else owner.get(sha)
            plus, minus = collections.Counter(), collections.Counter()
        elif line.startswith('diff --git '):
            keep = source(line.rstrip('\n').split(' b/', 1)[-1])
        elif not keep or line.startswith(('+++', '---')):
            continue
        elif line.startswith('+'):
            plus[line[1:].strip()] += 1
        elif line.startswith('-'):
            minus[line[1:].strip()] += 1
    flush()
    proc.wait()
    files = [f for f in subprocess.run(['git', '-C', repo, 'ls-tree', '-r', '--name-only', rev],
                                       capture_output=True, text=True, check=True).stdout.split('\n')
             if f and source(f)]
    unowned = 0
    with ThreadPoolExecutor(8) as pool:
        for counts in pool.map(lambda f: blame_file(repo, rev, f), files):
            for sha, n in counts.items():
                if sha in owner:
                    surviving[owner[sha]] += n
                else:
                    unowned += n
    return len(files), added, surviving, unowned


# --- report -----------------------------------------------------------------

def iso_day(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).date().isoformat()


def words(text):
    return len(text.split())


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--repo', default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument('--json', metavar='PATH', help='also write per-commit and per-prompt data (no prompt text)')
    ap.add_argument('--blame', metavar='REV', help='with --json, count source lines each commit added '
                    'on REV and how many survive there')
    args = ap.parse_args()
    # Crush's database lives in the main checkout, not in worktrees.
    main_repo = os.path.dirname(subprocess.run(
        ['git', '-C', args.repo, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
        capture_output=True, text=True, check=True).stdout.strip())

    harnesses = [read_claude(), read_crush(main_repo), read_opencode(), read_codex(), read_pi()]
    for h in harnesses:
        h.prompts = [(ts, t) for ts, t in h.prompts if not t.strip().startswith('/')]
    a = attribute(args.repo, harnesses)

    print(f"# Commits\n{a['commits']} non-merge on branches/tags/remotes, {a['distinct']} distinct")
    print(f"{a['logged_lines']} logged commit lines, {a['stale']} not resolvable to a ref")
    cal = a['calibration']
    print(f"time rule on log-verified commits: {cal[True]}/{cal[True] + cal[False]} correct\n")
    names = sorted({n for n, _ in a['table']}, key=lambda n: -sum(v for (m, _), v in a['table'].items() if m == n))
    print(f"{'harness':16} {'log':>5} {'trailer':>7} {'time':>5} {'total':>6}")
    for n in names:
        row = [a['table'][(n, k)] for k in ('log', 'trailer', 'time')]
        print(f'{n:16} {row[0]:5} {row[1]:7} {row[2]:5} {sum(row):6}')
    print('\n# Models by commit (log + trailer)')
    for n, c in a['models'].items():
        print(f'{n}: ' + ', '.join(f'{m} {v}' for m, v in c.most_common()))

    print('\n# Human prompts (slash commands excluded)')
    months = collections.defaultdict(collections.Counter)
    for h in harnesses:
        long = sum(words(t) > 10 for _, t in h.prompts)
        print(f'{h.name:12} {len(h.prompts):6} {long:6} (>10 words)')
        for ts, t in h.prompts:
            m = datetime.date.fromtimestamp(ts).strftime('%Y-%m')
            months[m][h.name] += 1
            months[m]['>10 words'] += words(t) > 10
    for m in sorted(months):
        print(m, dict(months[m]))

    print('\n# Usage')
    for h in harnesses:
        print(f'## {h.name}')
        if getattr(h, 'sessions', None) is not None:
            print('sessions:', h.sessions)
        for model, u in sorted(h.usage.items(), key=lambda x: -x[1].get('messages', x[1].get('rollouts', 0))):
            print(f'  {model}: ' + ', '.join(f'{k}={v}' for k, v in u.items()))

    if args.json:
        write_json(args, harnesses, a)


def write_json(args, harnesses, a):
    # A prompt sent verbatim three or more times is a loop tick, not a new instruction.
    seen = collections.Counter(' '.join(t.split()) for h in harnesses for _, t in h.prompts)
    records = sorted(a['records'], key=lambda r: r['at'])
    commits = [{k: r[k] for k in ('at', 'harness', 'method', 'model', 'family')} for r in records]
    # Tokens per UTC day, harness and model family. Crush stores no per-message
    # token counts (its session totals hold only the last turn), so its rows
    # carry the message count alone.
    days = collections.defaultdict(lambda: [0, 0, 0])
    for h in harnesses:
        if h.name == 'Crush':
            for ts, model in h.models:
                days[(iso_day(ts), h.name, model_family(model.split('/')[-1]))][0] += 1
            continue
        for ts, model, total, out in h.tokens:
            row = days[(iso_day(ts), h.name, model_family((model or '?').split('/')[-1]))]
            row[0] += 1
            row[1] += total
            row[2] += out
    data = {
        'generated': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
        'commits': commits,
        'tokens': [{'day': d, 'harness': h, 'family': f, 'messages': m,
                    'total': None if h == 'Crush' else t, 'output': None if h == 'Crush' else o}
                   for (d, h, f), (m, t, o) in sorted(days.items())],
        'prompts': sorted(({'ts': round(ts), 'harness': h.name, 'words': words(t),
                            'repeated': seen[' '.join(t.split())] >= 3}
                           for h in harnesses for ts, t in h.prompts), key=lambda p: p['ts']),
        'messages': {h.name: {m: u.get('messages', 0) for m, u in h.usage.items()} for h in harnesses},
        'calibration': [a['calibration'][True], sum(a['calibration'].values())],
    }
    if args.blame:
        nfiles, added, surviving, unowned = line_counts(args.repo, args.blame, records)
        for i, c in enumerate(commits):
            c['added'], c['surviving'] = added[i], surviving[i]
        data['lines'] = {'rev': args.blame, 'files': nfiles, 'unowned': unowned}
    with open(args.json, 'w') as f:
        json.dump(data, f, separators=(',', ':'))


if __name__ == '__main__':
    main()
