import re, sys, collections
# Parse macOS `sample` "Sort by top of stack" section and bucket self samples.
def buckets(path):
    text = open(path, errors='replace').read()
    m = re.search(r'Sort by top of stack, same collapsed \(when >= \d+\):\n(.*?)(\n\n|\Z)', text, re.S)
    if not m: return None, {}
    rows = []
    for line in m.group(1).splitlines():
        mm = re.match(r'\s*(.+?)\s+\(in ([^)]*)\)\s+(\d+)\s*$', line) or re.match(r'\s*(.+?)\s+(\d+)\s*$', line)
        if not mm: continue
        if len(mm.groups()) == 3: sym, lib, n = mm.group(1), mm.group(2), int(mm.group(3))
        else: sym, lib, n = mm.group(1), '', int(mm.group(2))
        rows.append((sym, lib, n))
    b = collections.Counter(); top = collections.Counter()
    for sym, lib, n in rows:
        s = sym
        if sym.startswith('???') or lib == '???' or re.match(r'^0x[0-9a-f]+$', sym): k = 'jit-code'
        elif re.search(r'\bth_|vm_dispatch|vm_execute|dispatch_property|Dispatch\.', s): k = 'interpreter'
        elif re.search(r'sljit_|ssa_|loop_prepare|loop_binding|FunctionEmitter|LoopEmitter|function_emit|jit::', s): k = 'jit-runtime/compile'
        elif re.search(r'gc|mark|sweep|minor|major|collect|trace_|remember|promot|Heap\.(alloc|free)|pagepool|PagePool', s, re.I): k = 'gc/alloc'
        elif re.search(r'mem(cpy|move|set|cmp)|_platform_|malloc|free|szone|nano', s): k = 'libc/memory'
        elif re.search(r'string|hstring|concat|intern|utf|str_', s, re.I): k = 'strings'
        elif re.search(r'regexp|lre_|re_', s, re.I): k = 'regexp'
        elif re.search(r'parse|lexer|compile|codegen|emit_|resolve|ast', s, re.I): k = 'frontend'
        elif re.search(r'prop|shape|ic_|mega|lookup|hobject', s, re.I): k = 'property/object'
        else: k = 'other'
        b[k] += n; top[(k, sym)] += n
    return sum(b.values()), b, top
for path in sys.argv[1:]:
    total, b, top = buckets(path)
    if not total: print(path, 'no data'); continue
    print('==', path.split('/')[-1], 'samples', total)
    print('   ' + '  '.join(f'{k} {100*v/total:.0f}%' for k, v in b.most_common()))
    for (k, s), n in top.most_common(8): print(f'      {100*n/total:5.1f}% [{k}] {s[:90]}')
