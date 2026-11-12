#!/usr/bin/env python3
"""Profile a boomkat run and attribute samples to engine functions and JIT code.

    python3 scripts/jit_profile.py [--delay S] [--seconds N] [--top K]
        [--callers PATTERN] [--annotate PATTERN] -- BIN [ENGINE ARGS] --script FILE

Runs BIN with --sample-pcs (the engine's own sampler, src/jit/pc_sampler.c: the pc and a short
call stack every millisecond, from --delay seconds on for --seconds) and --jit-dump-feedback (the
code map of the same process, so generated-code addresses match), lets it run to completion, and
prints: time by category (generated code / runtime helpers / other), the hottest runtime helpers,
time by function including its callees, the generated code by function, by bytecode op within a
function, by shared subroutine, and optimized code by the kind of graph node it was emitted for
(--opt-dump names the nodes). `fn#N` is the compiled function index (see the `feedback fn#N`
lines of --jit-dump-feedback to identify it); `opt` marks optimized code.

--callers PATTERN shows the call chains into the functions whose name contains PATTERN.
--annotate PATTERN prints the disassembly of the hottest engine function whose name contains
PATTERN with the samples at each instruction. Call chains follow frame pointers: a function that
keeps none (generated code may not) ends its chain.
"""
import argparse, bisect, collections, os, re, subprocess, sys, tempfile

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument('--delay', type=float, default=2.0, help='seconds before sampling starts')
ap.add_argument('--seconds', type=float, default=6, help='sampling duration')
ap.add_argument('--top', type=int, default=15)
ap.add_argument('--callers', help='show the call chains into functions whose name contains this')
ap.add_argument('--annotate', help='annotate the hottest engine function whose name contains this')
ap.add_argument('--keep', help='keep raw sample and map files with this path prefix')
ap.add_argument('cmd', nargs=argparse.REMAINDER)
a = ap.parse_args()
cmd = a.cmd[1:] if a.cmd and a.cmd[0] == '--' else a.cmd
if not cmd:
    ap.error('give the command after --')
tmp = tempfile.mkdtemp(prefix='jitprof.')
sample_path, map_path = os.path.join(tmp, 'samples.txt'), os.path.join(tmp, 'map.txt')
with open(map_path, 'w') as mf:
    rc = subprocess.run([cmd[0], '--jit-dump-feedback', '--sample-pcs=' + sample_path,
                         '--sample-after=%g' % a.delay, '--sample-for=%g' % a.seconds] + cmd[1:],
                        stdout=mf, stderr=subprocess.STDOUT).returncode
if not os.path.exists(sample_path):
    sys.exit('no samples (exit status %d); see %s' % (rc, map_path))

# The code map: generated code by address.
maps, subs = [], []
onodes = {}  # optimized code by start address: its node map as the latest compile there printed it
cur = None
for line in open(map_path, errors='replace'):
    if line.startswith('onodes '):
        p = line.split()
        nodes = []
        for tok in p[4:]:
            if tok.startswith('end:'):
                nodes.append((int(tok[4:], 16), 'stubs', '', ''))
            else:
                ad, op, pc, fidx = tok.split(':')[:4]
                nodes.append((int(ad, 16), op, pc, fidx))
        nodes.sort(key=lambda x: x[0])
        onodes[int(p[2], 16)] = (p[1], nodes)
    elif line.startswith('map '):
        p = line.split()
        # Subroutines and the call entry follow the instruction bodies.
        lo, hi = int(p[3], 16), int(p[4], 16)
        tail = min([x for x in (int(y, 16) for y in p[5:7]) if lo < x < hi] or [hi])
        cur = dict(fn=p[1], name=p[2], start=lo, end=tail, opt=line.rstrip().endswith('opt'), ents=[])
        maps.append(cur)
    elif line.startswith('sub '):
        q = line.split()
        subs.append((int(q[3], 16), q[1] + ' ' + q[2]))
    elif line.startswith('ents ') and cur:
        for tok in line.split()[2:]:
            ad, op = tok.split(':')[:2]
            cur['ents'].append((int(ad, 16), op))
# Code freed and reused by a later compile: the later lines describe it.
maps = sorted({m['start']: m for m in maps}.values(), key=lambda m: m['start'])
subs.sort()
starts = [m['start'] for m in maps]
sub_at = [s[0] for s in subs]

# The engine image's symbols, from its unslid addresses.
lines = open(sample_path).read().splitlines()
_, base_hex, binary = lines[0].split(' ', 2)
syms = []
header = 0
for l in subprocess.run(['nm', '-n', binary], capture_output=True, text=True).stdout.splitlines():
    p = l.split()
    if len(p) != 3:
        continue
    if p[2] in ('__mh_execute_header', '__ehdr_start'):
        header = int(p[0], 16)
    if p[1] in 'tT':
        syms.append((int(p[0], 16), p[2][1:] if sys.platform == 'darwin' and p[2].startswith('_') else p[2]))
syms.sort()
sym_at = [s[0] for s in syms]
slide = int(base_hex, 16) - header

def engine_sym(addr):
    """(name, offset, unslid start, unslid end) of the engine function holding `addr`."""
    u = addr - slide
    k = bisect.bisect_right(sym_at, u) - 1
    if k < 0:
        return ('?', 0, 0, 0)
    end = syms[k + 1][0] if k + 1 < len(syms) else u + 1
    return (syms[k][1], u - syms[k][0], syms[k][0], end)

def code_map(pc):
    i = bisect.bisect_right(starts, pc) - 1
    return maps[i] if i >= 0 and maps[i]['start'] <= pc < maps[i]['end'] else None

def node_at(start, pc):
    """The node of the optimized code at `start` whose code holds pc: (fn, op, pc, inlined fn)."""
    if start not in onodes:
        return None
    fn, nodes = onodes[start]
    k = bisect.bisect_right([x[0] for x in nodes], pc) - 1
    return (fn,) + nodes[k][1:] if k >= 0 else (fn, 'prologue', '', '')

def label(tok):
    """A function-level name for an address token of the sample file."""
    kind, _, rest = tok.partition(':')
    if kind == 'm':
        return engine_sym(int(rest, 16))[0]
    if kind == 'l':
        lib, _, sym = rest.partition(':')
        return '[%s] %s' % (lib, sym)
    if kind == 'u':
        pc = int(rest, 16)
        mp = code_map(pc)
        if mp:
            return mp['fn'] + (' opt' if mp['opt'] else '')
        j = bisect.bisect_right(sub_at, pc) - 1
        if j >= 0 and pc - sub_at[j] < 4096:
            return 'sub ' + subs[j][1]
        return 'generated (unmapped)'
    return '?'

total = 0
cat = collections.Counter()
helpers = collections.Counter()
inclusive = collections.Counter()
fns, ops, subc = collections.Counter(), collections.Counter(), collections.Counter()
hot = collections.Counter()
nodekinds, nodesites = collections.Counter(), collections.Counter()
callers = collections.Counter()
annot = collections.defaultdict(collections.Counter)  # engine function -> unslid address -> samples

for l in lines[1:]:
    toks = l.split()[1:]
    if not toks:
        continue
    total += 1
    leaf = toks[0]
    kind, _, rest = leaf.partition(':')
    name = label(leaf)
    if kind == 'u':
        pc = int(rest, 16)
        mp = code_map(pc)
        if mp:
            cat['generated code'] += 1
            tag = mp['fn'] + (' opt' if mp['opt'] else '')
            e = [x for x in mp['ents'] if x[0] <= pc]
            hot['%s +0x%x (op %s)' % (tag, pc - mp['start'], e[-1][1] if e else 'entry')] += 1
            fns[tag + ' n' + str(len(mp['ents']))] += 1
            ops[(tag, e[-1][1] if e else 'entry')] += 1
            nd = node_at(mp['start'], pc) if mp['opt'] else None
            if nd:
                nodekinds[nd[1]] += 1
                nodesites['%s %s pc %s%s' % (nd[0], nd[1], nd[2], ' (inlined fn %s)' % nd[3] if nd[3] not in ('', '0') else '')] += 1
        elif name.startswith('sub '):
            cat['generated code'] += 1
            subc[name[4:]] += 1
        else:
            cat['generated code (unmapped)'] += 1
    elif kind == 'm':
        cat['runtime helpers'] += 1
        helpers[name] += 1
        s = engine_sym(int(rest, 16))
        annot[name][s[2] + s[1]] += 1
    else:
        cat['other (libc, kernel)'] += 1
        helpers[name] += 1
    # The callers: the link register when it is not inside the function itself (then it is
    # stale or the leaf's own frame holds the same return), then the frame chain.
    chain = [name]
    for t in toks[1:]:
        if t == '0':
            continue
        n = label(t)
        if n != chain[-1]:
            chain.append(n)
    for n in set(chain):
        inclusive[n] += 1
    if a.callers and a.callers in name:
        callers[' < '.join(chain[:4])] += 1

def show(title, counter, k=a.top):
    print('\n-- ' + title)
    for key, v in counter.most_common(k):
        print('%6.1f%%  %6d  %s' % (100.0 * v / max(total, 1), v, key if isinstance(key, str) else ' '.join(key)))

print('samples: %d (%g s from %g s on, every millisecond)' % (total, a.seconds, a.delay))
show('category', cat)
show('runtime helpers / other (self)', helpers)
show('functions including their callees (as far as frame pointers reach)', inclusive)
show('generated code by function', fns)
show('generated code by function + bytecode op', ops, a.top + 10)
show('shared subroutines', subc)
if nodekinds:
    show('optimized code by node kind (stubs: exits, polls and call entry after the nodes)', nodekinds)
    show('optimized code by node (function, kind, bytecode pc)', nodesites, a.top + 10)
show('hottest generated-code addresses (offset from the function start; scripts/jit_disasm.py)', hot, 12)
if a.callers:
    show('call chains into *%s*, innermost first' % a.callers, callers, a.top + 10)
if a.annotate:
    matching = [(sum(c.values()), f) for f, c in annot.items() if a.annotate in f]
    if not matching:
        print('\nno samples in an engine function matching %r' % a.annotate)
    else:
        n, f = max(matching)
        counts = annot[f]
        _, _, lo, hi = engine_sym(next(iter(counts)) + slide)
        print('\n-- %s: %d samples (%.1f%%), per instruction' % (f, n, 100.0 * n / max(total, 1)))
        dis = subprocess.run(['objdump', '-d', '--no-show-raw-insn', '--start-address=0x%x' % lo,
                              '--stop-address=0x%x' % hi, binary], capture_output=True, text=True).stdout
        for dl in dis.splitlines():
            m = re.match(r'\s*([0-9a-f]+):\s*(.*)', dl)
            if not m:
                continue
            c = counts.get(int(m.group(1), 16), 0)
            print('%6s  %5x  %s' % (c or '', int(m.group(1), 16) - lo, m.group(2)))
if a.keep:
    os.replace(sample_path, a.keep + '.samples.txt')
    os.replace(map_path, a.keep + '.map.txt')
    print('\nkept %s.samples.txt and %s.map.txt' % (a.keep, a.keep))
