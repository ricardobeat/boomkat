#!/usr/bin/env python3
"""Differential fuzz of RegExp against node.

    python3 scripts/regexp_fuzz.py [--seed N] [--cases N] [--bin ./out/boomkat] [--keep FILE]

Random patterns from a small grammar, random narrow and wide subjects, every flag combination of
`dgimsuvy` that node accepts, run through exec, test, replace (string and function replacers),
split, match, matchAll and search. Each case runs in a function called enough times for both JIT
tiers to compile it, so the interpreter, `--jit` and `--jit --opt` each answer from their own code;
every answer is compared with node's. Exits non-zero on any difference.
"""
import argparse, json, random, subprocess, sys, tempfile

ATOMS = ['a', 'b', 'c', 'ab', '.', '\\d', '\\w', '\\s', '\\D', '\\W', '[a-c]', '[^ab]', '[\\d_]',
         'é', 'ß', 'Σ', 'σ', '\\u00e9', 'K', 'k', '\\.']
ASSERTIONS = ['\\b', '\\B', '^', '$']
QUANTS = ['', '', '', '*', '+', '?', '*?', '+?', '{2}', '{1,3}', '{0,2}?']
SUBJECT_UNITS = list('aabbcc  _.\n') + ['1', '22', 'é', 'É', 'ß', 'Σ', 'σ', 'ς', 'K', 'K', '😀', '\ud83d']
FLAGS = 'dgimsuy'


def piece(r, depth, names):
    k = r.random()
    if k < 0.1:
        return r.choice(ASSERTIONS)
    if depth < 3 and k < 0.25:
        kind = r.choice(['(', '(', '(?:', 'named', '(?=', '(?!', '(?<=', '(?<!'])
        if kind == 'named':
            kind = '(?<n%d>' % len(names)
            names.append(kind)
        inner = alt(r, depth + 1, names)
        if kind.startswith('(?=') or kind.startswith('(?!') or kind.startswith('(?<=') or kind.startswith('(?<!'):
            return kind + inner + ')'
        return kind + inner + ')' + r.choice(QUANTS)
    return r.choice(ATOMS) + r.choice(QUANTS)


def seq(r, depth, names):
    return ''.join(piece(r, depth, names) for _ in range(r.randint(1, 4)))


def alt(r, depth=0, names=None):
    if names is None:
        names = []
    return '|'.join(seq(r, depth, names) for _ in range(r.choice([1, 1, 1, 2, 3])))


def subject(r):
    return ''.join(r.choice(SUBJECT_UNITS) for _ in range(r.randint(0, 14)))


OPS = ['exec', 'test', 'replace', 'replace$', 'replacefn', 'split', 'match', 'matchAll', 'search', 'execloop']

PRELUDE = r'''
var out = typeof print == "function" ? print : console.log;
function enc(v) {
  if (v === undefined) return "U";
  if (v === null) return null;
  if (Array.isArray(v)) {
    var a = v.map(enc);
    if (v.index !== undefined) a.push("@" + v.index);
    if (v.groups !== undefined) a.push(v.groups === undefined ? "G-" : JSON.stringify(Object.entries(v.groups).map(function (e) { return [e[0], enc(e[1])]; })));
    if (v.indices !== undefined) a.push(JSON.stringify(v.indices));
    return a;
  }
  if (typeof v == "object" && typeof v.next == "function") { var r = []; for (var m of v) r.push(enc(m)); return r; }
  return v;
}
function run(src, flags, op, s) {
  var re;
  try { re = new RegExp(src, flags); } catch (e) { return "SyntaxError"; }
  try {
    var r;
    switch (op) {
      case "exec": r = [re.exec(s), re.lastIndex]; break;
      case "test": r = [re.test(s), re.lastIndex, re.test(s), re.lastIndex]; break;
      case "replace": r = s.replace(re, "<$&>"); break;
      case "replace$": r = s.replace(re, "[$1|$<n0>|$`|$'|$$]"); break;
      case "replacefn": r = s.replace(re, function () { return "{" + Array.prototype.slice.call(arguments, 0, -2).join(",") + "}"; }); break;
      case "split": r = s.split(re); break;
      case "match": r = s.match(re); break;
      case "matchAll": r = re.global ? s.matchAll(re) : "nog"; break;
      case "search": r = s.search(re); break;
      case "execloop":
        r = []; var n = 0, m;
        if (!re.global && !re.sticky) { r = enc(re.exec(s)); break; }
        while ((m = re.exec(s)) && n++ < 20) { r.push(enc(m)); if (m[0] === "") re.lastIndex++; }
        r.push(re.lastIndex);
        break;
    }
    return enc(r);
  } catch (e) { return "E:" + e.constructor.name; }
}
function warm(src, flags, op, s) {
  var first = JSON.stringify(run(src, flags, op, s));
  for (var i = 0; i < REPS; i++) {
    var again = JSON.stringify(run(src, flags, op, s));
    if (again !== first) return "UNSTABLE " + first + " / " + again;
  }
  return first;
}
'''


def build(cases, reps):
    lines = ['var REPS = %d;' % reps, PRELUDE, 'var C = ' + json.dumps(cases) + ';',
             'for (var i = 0; i < C.length; i++) out(i + " " + warm(C[i][0], C[i][1], C[i][2], C[i][3]));']
    return '\n'.join(lines)


def run(cmd, path):
    p = subprocess.run(cmd + [path], capture_output=True, text=True, errors='replace', timeout=1800)
    return p.stdout.splitlines(), p.returncode, p.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--cases', type=int, default=3000)
    ap.add_argument('--reps', type=int, default=40)
    ap.add_argument('--bin', default='./out/boomkat')
    ap.add_argument('--keep')
    a = ap.parse_args()
    r = random.Random(a.seed)
    cases = []
    for _ in range(a.cases):
        flags = ''.join(f for f in FLAGS if r.random() < 0.3)
        if r.random() < 0.1:
            flags = flags.replace('u', '') + 'v'
        op = r.choice(OPS)
        s = subject(r)
        # V8 and JavaScriptCore both try a unicode split at the second unit of a surrogate pair,
        # where @@split's AdvanceStringIndex steps over the pair (ECMA-262 22.2.6.14 step 19).
        if op == 'split' and ('u' in flags or 'v' in flags) and any(ord(c) > 0xffff for c in s):
            s = s.replace('\U0001F600', '\u00e9')
        cases.append([alt(r), flags, op, s])
    src = build(cases, a.reps)
    with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False) as f:
        f.write(src)
        path = f.name
    if a.keep:
        open(a.keep, 'w').write(src)
    want, rc, err = run(['node'], path)
    if rc != 0:
        print('node failed:', err[:2000])
        return 2
    bad = 0
    for mode in ([], ['--jit'], ['--jit', '--opt']):
        got, rc, err = run([a.bin] + mode + ['--script'], path)
        name = ' '.join(mode) or 'interp'
        if rc != 0:
            print('%s: exit %d %s' % (name, rc, err[:500]))
            bad += 1
        diffs = [(w, g) for w, g in zip(want, got) if w != g]
        if len(got) != len(want):
            diffs.append(('%d lines' % len(want), '%d lines' % len(got)))
        for w, g in diffs[:10]:
            i = int(w.split(' ', 1)[0]) if w[:1].isdigit() else -1
            print('%s: case %s\n  node: %s\n  boomkat: %s' % (name, cases[i] if i >= 0 else '?', w[:300], g[:300]))
        print('%s: %d/%d differ' % (name, len(diffs), len(want)))
        bad += len(diffs)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
