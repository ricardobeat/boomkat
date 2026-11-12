#!/usr/bin/env python3
"""Disassemble the optimized code boomkat generates, node by node.

    python3 scripts/jit_disasm.py [--fn N] [--all] [--node-op OP] -- BIN [ENGINE ARGS] --script FILE

Runs BIN with --jit-dump-code (add --jit --opt to the engine arguments) and prints the machine code
of each optimized body under the graph node it was emitted for: `n<index> <OP> pc <bytecode pc>`,
with `fn <k>` for a node of an inlined callee. Node indexes match --opt-dump, so running the same
command with --opt-dump shows each node's operands. The code after the last node holds the exit
stubs, polls and the call entry.

By default the last body compiled for each function is shown; --fn picks one function (the fn#N of
--opt-log and scripts/jit_profile.py), --all shows every compile, and --node-op shows only the nodes
of one kind, with a count of instructions per node. Disassembly uses llvm-mc (PATH, then Homebrew's
llvm), or --mc PATH.
"""
import argparse, os, platform, re, shutil, subprocess, sys
from collections import OrderedDict

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument('--fn', type=int, help='only this function (fn#N)')
ap.add_argument('--all', action='store_true', help='every compile, not only the last per function')
ap.add_argument('--node-op', help='only nodes of this kind, e.g. LOAD_FIELD')
ap.add_argument('--mc', help='llvm-mc to use')
ap.add_argument('cmd', nargs=argparse.REMAINDER)
args = ap.parse_args()
cmd = args.cmd[1:] if args.cmd[:1] == ['--'] else args.cmd
if not cmd:
    ap.error('give the engine command after --')

mc = args.mc or shutil.which('llvm-mc')
for cand in ('/opt/homebrew/opt/llvm/bin/llvm-mc', '/usr/local/opt/llvm/bin/llvm-mc'):
    if mc is None and os.path.exists(cand):
        mc = cand
if mc is None:
    sys.exit('jit_disasm: llvm-mc not found; install LLVM or pass --mc')
triple = {'arm64': 'arm64', 'aarch64': 'aarch64', 'x86_64': 'x86_64', 'AMD64': 'x86_64'}.get(platform.machine())
if triple is None:
    sys.exit('jit_disasm: unsupported host ' + platform.machine())

run = subprocess.run([cmd[0], '--jit-dump-code'] + cmd[1:], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                     text=True, errors='replace')

# fn#N -> list of (start, nodes, code); nodes are (address, op, pc, fn, index, opcode), sorted by
# address.
bodies = OrderedDict()
pending = None
for line in run.stderr.splitlines():
    if line.startswith('onodes '):
        p = line.split()
        nodes = []
        for tok in p[4:]:
            if tok.startswith('end:'):
                nodes.append((int(tok[4:], 16), 'stubs', '', '0', '', ''))
            else:
                ad, op, pc, fidx, idx, opcode = (tok.split(':') + [''])[:6]
                nodes.append((int(ad, 16), op, pc, fidx, idx, opcode))
        nodes.sort(key=lambda x: x[0])
        pending = (p[1], nodes)
    elif line.startswith('ocode ') and pending is not None:
        _, fn, start, hexcode = line.split()
        assert fn == pending[0]
        bodies.setdefault(fn, []).append((int(start, 16), pending[1], bytes.fromhex(hexcode)))
        pending = None
if not bodies:
    sys.stderr.write(run.stderr[-2000:])
    sys.exit('jit_disasm: no optimized code was printed (are --jit --opt among the engine arguments?)')

enc_re = re.compile(r'encoding: \[([^\]]*)\]')

def disassemble(code):
    """(offset, text) per instruction."""
    src = ' '.join('0x%02x' % b for b in code)
    out = subprocess.run([mc, '--disassemble', '--show-encoding', '-triple=' + triple], input=src,
                         capture_output=True, text=True).stdout
    insns, off = [], 0
    for line in out.splitlines():
        m = enc_re.search(line)
        if not m:
            continue
        text = line[:m.start()].strip().rstrip(';').strip()
        insns.append((off, text))
        off += len(m.group(1).split(','))
    return insns

def show(fn, start, nodes, code):
    insns = disassemble(code)
    print('== %s at %#x, %d bytes, %d instructions' % (fn, start, len(code), len(insns)))
    bounds = [(n[0] - start,) + n[1:] for n in nodes]
    k = 0
    counts = {}
    current = None
    for off, text in insns:
        while k < len(bounds) and bounds[k][0] <= off:
            current = bounds[k]
            k += 1
            if args.node_op is None or current[1] == args.node_op:
                where = ('pc %s %s' % (current[2], current[5])) + (' fn %s' % current[3] if current[3] not in ('0', '') else '')
                print('  n%s %s %s' % (current[4], current[1], where) if current[1] != 'stubs' else '  stubs')
        if current is None:
            label = 'prologue'
        else:
            label = current[1]
        if args.node_op is None or label == args.node_op:
            print('    %6x  %s' % (off, text))
            if current is not None:
                counts[current[4]] = counts.get(current[4], 0) + 1
    if args.node_op:
        n = list(counts.values())
        if n:
            print('  %d %s nodes, %d instructions, %.1f per node' % (len(n), args.node_op, sum(n), sum(n) / len(n)))

for fn, compiles in bodies.items():
    if args.fn is not None and fn != 'fn#%d' % args.fn:
        continue
    for start, nodes, code in (compiles if args.all else compiles[-1:]):
        show(fn, start, nodes, code)
