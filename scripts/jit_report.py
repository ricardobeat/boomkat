#!/usr/bin/env python3
"""Explain what the optimizing JIT did with a program, function by function.

    python3 scripts/jit_report.py [options] -- BIN [ENGINE ARGS] FILE

Runs the program with --jit --opt --opt-log (added when missing) and reads the optimizer's log:

  - compiles: each optimized build, how many calls it inlined, and how the calls it kept were
    lowered: `reg` (a register call: the proven callee's entry on a native frame of its own, the
    caller's values kept in registers), `direct` (the proven callee's entry) or `generic` (the
    full call protocol).
  - exits: where optimized code fell back to baseline code, by instruction and reason, including
    exits from inlined bodies (attributed to the callee, with the function they were inlined in).
  - discards and refusals: builds thrown away after repeated exits, functions the tier declined.
  - inline rejects: call sites that stayed calls, and why.

Functions are named `fn#N name:line` (N is the compile index, line the function's first line).
The program's own stdout is passed through unless --quiet. Sort with --sort exits|calls|compiles.
"""
import argparse, collections, re, subprocess, sys

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument('--top', type=int, default=20, help='functions to list (default 20, 0 for all)')
ap.add_argument('--sort', choices=['exits', 'calls', 'compiles'], default='exits')
ap.add_argument('--quiet', action='store_true', help="hide the program's own output")
ap.add_argument('--log', help='also save the raw optimizer log here')
ap.add_argument('cmd', nargs=argparse.REMAINDER)
a = ap.parse_args()
cmd = a.cmd[1:] if a.cmd and a.cmd[0] == '--' else a.cmd
if len(cmd) < 2:
    ap.error('give the engine and the program after --')
for flag in ('--jit', '--opt', '--opt-log'):
    if flag not in cmd:
        cmd.insert(1, flag)

proc = subprocess.run(cmd, stdout=None if not a.quiet else subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, errors='replace')
log = proc.stderr.splitlines()
if a.log:
    with open(a.log, 'w') as f:
        f.write(proc.stderr)

FN = r'(fn#\d+ \S+?:\d+)'
pats = {
    'compile': re.compile(r'^opt compile ' + FN + r' words (\d+) nodes (\d+) inlined (\d+) reopt (\d+)(?: region (\S+))?(?: calls reg (\d+) direct (\d+) generic (\d+))?$'),
    'exit': re.compile(r'^opt exit ' + FN + r' \+(\d+) (\S+) (\S+)(?: inlined in ' + FN + ')?'),
    'discard': re.compile(r'^opt discard ' + FN + r' exits (\d+)'),
    'refuse': re.compile(r'^opt refuse ' + FN + r' (.+?) (\S+) words (\d+) registers (\d+)$'),
    'generic': re.compile(r'^opt generic-call ' + FN + r' \+(\d+) (\S+) (\S+)$'),
    'reject': re.compile(r'^opt inline-reject ' + FN + r' \+(\d+)(?: -> ' + FN + r')? (.+)$'),
}

class Fn:
    def __init__(self, name):
        self.name = name
        self.compiles = 0
        self.words = 0
        self.inlined = 0
        self.calls = [0, 0, 0]
        self.region = False
        self.exits = collections.Counter()      # (pc, op, reason, host) -> count
        self.discards = 0
        self.refused = None
        self.rejects = collections.Counter()    # (pc, callee, why) -> count
        self.generic = []                       # (pc, op, why) of the latest build's generic calls

fns = {}
def fn(name):
    if name not in fns:
        fns[name] = Fn(name)
    return fns[name]

other = []
for line in log:
    m = pats['compile'].match(line)
    if m:
        f = fn(m[1]); f.compiles += 1; f.words = int(m[2]); f.inlined = int(m[4])
        f.region = f.region or m[6] is not None
        if m[7] is not None:
            f.calls = [int(m[7]), int(m[8]), int(m[9])]
        f.generic = []
        continue
    m = pats['generic'].match(line)
    if m:
        fn(m[1]).generic.append((int(m[2]), m[3], m[4]))
        continue
    m = pats['exit'].match(line)
    if m:
        fn(m[1]).exits[(int(m[2]), m[3], m[4], m[5])] += 1
        continue
    m = pats['discard'].match(line)
    if m:
        fn(m[1]).discards += 1
        continue
    m = pats['refuse'].match(line)
    if m:
        fn(m[1]).refused = '%s (%s)' % (m[2], m[3]) if m[3] != 'NOP' else m[2]
        continue
    m = pats['reject'].match(line)
    if m:
        fn(m[1]).rejects[(int(m[2]), m[3] or '?', m[4])] += 1
        continue
    if not line.startswith('opt '):
        other.append(line)

if other and not a.quiet:
    sys.stderr.write('\n'.join(other) + '\n')

allf = list(fns.values())
tot_exits = sum(sum(f.exits.values()) for f in allf)
tot_calls = [sum(f.calls[i] for f in allf) for i in range(3)]
print('\n== JIT report: %d functions optimized (%d builds), %d refused, %d discarded builds, %d exits'
      % (sum(1 for f in allf if f.compiles), sum(f.compiles for f in allf), sum(1 for f in allf if f.refused),
         sum(f.discards for f in allf), tot_exits))
print('   calls kept in the latest builds: %d register, %d direct, %d generic; %d inlined'
      % (tot_calls[0], tot_calls[1], tot_calls[2], sum(f.inlined for f in allf)))

key = {'exits': lambda f: (sum(f.exits.values()), f.compiles),
       'calls': lambda f: (f.calls[2], f.calls[1], f.compiles),
       'compiles': lambda f: (f.compiles, sum(f.exits.values()))}[a.sort]
shown = sorted((f for f in allf if f.compiles or f.exits or f.refused), key=key, reverse=True)
if a.top:
    shown = shown[:a.top]

print('\n%-34s %6s %5s %5s %5s %5s %4s %4s %4s  %s' % ('function', 'builds', 'disc', 'exits', 'words', 'inl', 'reg', 'dir', 'gen', 'notes'))
for f in shown:
    notes = []
    if f.region: notes.append('region')
    if f.refused: notes.append('refused: ' + f.refused)
    print('%-34s %6d %5d %5d %5d %5d %4d %4d %4d  %s' % (f.name[:34], f.compiles, f.discards, sum(f.exits.values()),
          f.words, f.inlined, f.calls[0], f.calls[1], f.calls[2], ', '.join(notes)))

def section(title, rows):
    if rows:
        print('\n' + title)
        for r in rows:
            print('  ' + r)

gr = collections.Counter(why for f in allf for (_, _, why) in f.generic)
section('Generic calls of the latest builds by reason (no-feedback: the site never ran):',
        ['%6d  %s' % (n, why) for why, n in gr.most_common()])

ex = collections.Counter()
for f in allf:
    for (pc, op, why, host), n in f.exits.items():
        ex[(f.name, pc, op, why, host)] += n
section('Hottest exits (count  function +pc  instruction  reason):',
        ['%6d  %s +%d  %s  %s%s' % (n, name, pc, op, why, '  (inlined in %s)' % host if host else '')
         for (name, pc, op, why, host), n in ex.most_common(a.top or None)])

rj = collections.Counter()
for f in allf:
    for (pc, callee, why), n in f.rejects.items():
        rj[why] += n
section('Inline rejections by reason:', ['%6d  %s' % (n, why) for why, n in rj.most_common(a.top or None)])
sys.exit(proc.returncode)
