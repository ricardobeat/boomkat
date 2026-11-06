#!/usr/bin/env python3
"""Profile a boomkat run and attribute samples to JIT code.

    python3 scripts/jit_profile.py [--delay S] [--seconds N] [--top K] -- BIN [ENGINE ARGS] --script FILE

Runs BIN with --jit-dump-feedback (the code map is printed at exit by the same process that is
sampled, so the addresses match), samples it with /usr/bin/sample, and prints: time by category
(generated code / runtime helpers / other), the hottest runtime helpers, and the generated code by
function, by bytecode op within a function, and by shared subroutine. `fn#N` is the compiled
function index (see the `feedback fn#N` lines of --jit-dump-feedback to identify it); `opt` marks
optimized code. /usr/bin/sample needs the sandbox disabled (run this from a shell that allows it);
profile a mid-run window with --delay (the run must still be going when sampling starts).
Samples in addresses seen fewer than 5 times are collapsed by `sample` and are not attributed.
"""
import argparse, bisect, collections, os, re, subprocess, sys, tempfile, time

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument('--delay', type=float, default=2.0, help='seconds to wait before sampling')
ap.add_argument('--seconds', type=int, default=6, help='sampling duration')
ap.add_argument('--top', type=int, default=15)
ap.add_argument('--keep', help='keep raw sample and map files with this path prefix')
ap.add_argument('cmd', nargs=argparse.REMAINDER)
a = ap.parse_args()
cmd = a.cmd[1:] if a.cmd and a.cmd[0] == '--' else a.cmd
if not cmd:
    ap.error('give the command after --')
tmp = tempfile.mkdtemp(prefix='jitprof.')
sample_path, map_path = os.path.join(tmp, 'sample.txt'), os.path.join(tmp, 'map.txt')
with open(map_path, 'w') as mf:
    proc = subprocess.Popen([cmd[0], '--jit-dump-feedback'] + cmd[1:], stdout=mf, stderr=subprocess.STDOUT)
time.sleep(a.delay)
if proc.poll() is not None:
    sys.exit('the program exited before sampling started; lower --delay or use a longer run')
r = subprocess.run(['/usr/bin/sample', str(proc.pid), str(a.seconds), '-file', sample_path],
                   capture_output=True, text=True)
if not os.path.exists(sample_path):
    proc.kill()
    sys.exit('sample failed (sandbox? permissions?): ' + r.stderr.strip()[:300])
proc.wait()

maps, subs = [], []
cur = None
for line in open(map_path, errors='replace'):
    if line.startswith('map '):
        p = line.split()
        cur = dict(fn=p[1], name=p[2], start=int(p[3], 16), end=int(p[4], 16), opt=line.rstrip().endswith('opt'), ents=[])
        maps.append(cur)
    elif line.startswith('sub '):
        q = line.split()
        subs.append((int(q[3], 16), q[1] + ' ' + q[2]))
    elif line.startswith('ents ') and cur:
        for tok in line.split()[2:]:
            ad, op = tok.split(':')
            cur['ents'].append((int(ad, 16), op))
maps.sort(key=lambda m: m['start'])
subs.sort()
starts = [m['start'] for m in maps]
sub_at = [s[0] for s in subs]

text = open(sample_path, errors='replace').read()
try:
    block = text[text.index('Sort by top of stack'):text.index('Binary Images')]
except ValueError:
    sys.exit('no sample data in ' + sample_path)
total = 0
cat = collections.Counter()
helpers = collections.Counter()
fns, ops, subc = collections.Counter(), collections.Counter(), collections.Counter()
hot = collections.Counter()
for l in block.splitlines()[1:]:
    m = re.match(r'\s+(.*?)\s+\(in (.*?)\)\s+(?:\[(0x[0-9a-f]+)\]\s+)?(\d+)$', l)
    if not m:
        continue
    sym, binary, addr, n = m.group(1), m.group(2), m.group(3), int(m.group(4))
    total += n
    if 'unknown' in binary and addr:
        pc = int(addr, 16)
        i = bisect.bisect_right(starts, pc) - 1
        if i >= 0 and maps[i]['start'] <= pc < maps[i]['end']:
            mp = maps[i]
            cat['generated code'] += n
            hot['%s%s +0x%x (op %s)' % (mp['fn'], ' opt' if mp['opt'] else '', pc - mp['start'], (([x for x in mp['ents'] if x[0] <= pc] or [(0, 'entry')])[-1][1]))] += n
            fns[mp['fn'] + (' opt' if mp['opt'] else '') + ' n' + str(len(mp['ents']))] += n
            e = [x for x in mp['ents'] if x[0] <= pc]
            ops[(mp['fn'] + (' opt' if mp['opt'] else ''), e[-1][1] if e else 'entry')] += n
        else:
            j = bisect.bisect_right(sub_at, pc) - 1
            if j >= 0 and pc - sub_at[j] < 4096:
                cat['generated code'] += n
                subc[subs[j][1]] += n
            else:
                cat['generated code (unmapped)'] += n
    elif binary.startswith('boomkat') or 'boomkat' in binary:
        cat['runtime helpers'] += n
        helpers[sym] += n
    else:
        cat['other (libc, kernel)'] += n
        helpers['[' + binary + '] ' + sym] += n

def show(title, counter, k=a.top):
    print('\n-- ' + title)
    for key, v in counter.most_common(k):
        print('%6.1f%%  %6d  %s' % (100.0 * v / max(total, 1), v, key if isinstance(key, str) else ' '.join(key)))

print('samples attributed: %d (%d s window after %.1f s)' % (total, a.seconds, a.delay))
show('category', cat)
show('runtime helpers / other', helpers)
show('generated code by function', fns)
show('generated code by function + bytecode op', ops, a.top + 10)
show('shared subroutines', subc)
show('hottest addresses (offset from the function start; disassemble with lldb: image/memory around start+offset)', hot, 12)
if a.keep:
    os.replace(sample_path, a.keep + '.sample.txt')
    os.replace(map_path, a.keep + '.map.txt')
    print('\nkept %s.sample.txt and %s.map.txt' % (a.keep, a.keep))
