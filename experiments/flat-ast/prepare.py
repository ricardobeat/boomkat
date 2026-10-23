#!/usr/bin/env python3
"""Generate bounded targeted workloads and ordinary-code compile controls."""
from pathlib import Path
import json
ROOT = Path(__file__).resolve().parents[2]
DEST = Path(__file__).resolve().parent / 'workloads'
DEST.mkdir(exist_ok=True)

def runtime(name, kernel, invocation, expected, count=1000000):
    (DEST / (name + '.js')).write_text(kernel + '\nvar total = 0;\nfor (var i = 0; i < ' + str(count) + '; i++) total += ' + invocation + ';\nif (total !== ' + str(expected) + ') throw new Error("checksum: " + total);\nprint(total);\n')

runtime('long_numeric', 'function kernel(x) { return x + (' + '+'.join(['1']*128) + '); }', 'kernel(i & 255)', 255493856)
runtime('primitive_bitwise', 'function kernel(x) { return x + ((true << 5) + (null ^ 3) + +"12" + (false ? 0 : 7)); }', 'kernel(i & 255)', 181493856)
runtime('literal_strings', 'function kernel(prefix) { return prefix + ("mode:" + true + ":" + (1 << 3)); }', 'kernel("p" + (i & 7)).length', 5200000, 400000)
runtime('dynamic_strings_control', 'function kernel(prefix, label, enabled, count) { return prefix + (label + enabled + ":" + count); }', 'kernel("p" + (i & 7), "mode:", true, 8).length', 5200000, 400000)
runtime('local_const_chain', 'function kernel(x) { const scale = 2; const offset = scale + 3; const mask = (offset << 1) - 1; return (x & mask) + offset; }', 'kernel(i & 255)', 9500000)
runtime('explicit_constants_control', 'function kernel(x) { return (x & 9) + 5; }', 'kernel(i & 255)', 9500000)

cases = {
    'compile_long_numeric': ['function f%d(x){return x+(' % i + '+'.join(['1']*128) + ');}' for i in range(1000)],
    'compile_local_const': ['function f%d(x){const a=2;const b=a+3;const c=(b<<1)-1;return (x&c)+b;}' % i for i in range(3000)],
    'compile_strings': ['function f%d(x){return x+("mode:"+true+":"+(1<<3));}' % i for i in range(3000)],
    'compile_dynamic_control': ['function f%d(x,y,z){let total=(x+y)*z;return total-x/y;}' % i for i in range(3000)],
    'compile_literals_control': ['function f%d(){return [%s];}' % (i, ','.join(map(str,range(24)))) for i in range(2000)],
}
scene = (ROOT/'test/benchmarks/bench_scene_churn.js').read_text()
cases['compile_scene_control'] = ['function sample%d(){\n%s\n}' % (i,scene) for i in range(50)]
for name, lines in cases.items():
    (DEST/(name+'.js')).write_text('\n'.join(lines)+'\n')
manifest = []
for name in ['long_numeric','primitive_bitwise','literal_strings','dynamic_strings_control','local_const_chain','explicit_constants_control']:
    manifest.append({'name':name,'kind':'runtime','path':str((DEST/(name+'.js')).relative_to(ROOT)),'group':'target' if name in ['long_numeric','primitive_bitwise','literal_strings','local_const_chain'] else 'matched control'})
for name,path in [('old_short_constants','ast-optimization/bench_ast_constants'),('dynamic_arithmetic_control','ast-optimization/bench_ast_constants_control'),('arithmetic','bench_arithmetic'),('array','bench_array'),('object','bench_object'),('recursion','bench_recursion'),('scene_churn','bench_scene_churn')]:
    manifest.append({'name':name,'kind':'runtime','path':'test/benchmarks/'+path+'.js','group':'old optimizer control' if name=='old_short_constants' else 'existing control'})
for name in cases:
    manifest.append({'name':name,'kind':'compile','path':str((DEST/(name+'.js')).relative_to(ROOT)),'group':'synthetic target' if name in ['compile_long_numeric','compile_local_const','compile_strings'] else 'synthetic control'})
manifest.append({'name':'compile_existing_scene','kind':'compile','path':'test/benchmarks/bench_scene_churn.js','group':'existing control'})
(Path(__file__).resolve().parent/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Prepared',len(manifest),'workloads')
