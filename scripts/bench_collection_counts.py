#!/usr/bin/env python3
"""Interleaved, checked Map/Set count benchmarks using immutable binaries."""
import argparse
import fnmatch
import json
import re
from pathlib import Path
import statistics
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('baseline', type=Path)
p.add_argument('candidate', type=Path)
p.add_argument('--out', type=Path, required=True)
p.add_argument('--pairs', type=int, default=7)
p.add_argument('--only', default='*', help='workload name glob')
p.add_argument('--controls', action='store_true', help='also time unchanged ES5/ES6 fixtures')
a = p.parse_args()
a.out.mkdir(parents=True, exist_ok=True)
binaries = [a.baseline.resolve(), a.candidate.resolve()]
workloads = {}
for kind in ['Map', 'Set']:
    add = 'c.set(i, i)' if kind == 'Map' else 'c.add(i)'
    for n in [1024, 8192]:
        workloads[f'{kind.lower()}_size_{n}'] = f'''
var c = new {kind}();
for (var i=0;i<{n};i++) {{ {add}; }}
var sum=0;
for (var i=0;i<100000;i++) sum+=c.size;
if(sum!=={n*100000}) throw new Error('size checksum');
print('ok');
'''
    workloads[f'{kind.lower()}_grow_size'] = f'''
var c=new {kind}(), sum=0;
for(var i=0;i<16000;i++) {{ {add}; sum+=c.size; }}
if(sum!==128008000) throw new Error('growth checksum');
print('ok');
'''
    workloads[f'{kind.lower()}_insert_has'] = f'''
var sum=0;
for(var round=0;round<40;round++) {{
 var c=new {kind}();
 for(var i=0;i<16000;i++) {{ {add}; }}
 for(var i=0;i<16000;i++) if(c.has(i)) sum++;
}}
if(sum!==640000) throw new Error('insert checksum');
print('ok');
'''
    workloads[f'{kind.lower()}_deleted_size'] = f"""
var c=new {kind}();
for(var i=0;i<8192;i++) {{ {add}; }}
for(var i=0;i<8192;i+=2) c.delete(i);
var sum=0; for(var i=0;i<100000;i++) sum+=c.size;
if(sum!==409600000) throw new Error('deleted checksum');
print('ok');
"""
    workloads[f'{kind.lower()}_retained_small'] = f'''
var all=[];
for(var j=0;j<100000;j++) {{ var c=new {kind}(); for(var i=0;i<2;i++) {{ {add}; }} all.push(c); }}
var sum=0; for(var j=0;j<all.length;j++) sum+=all[j].size;
if(sum!==200000) throw new Error('retention checksum');
print('ok');
'''
files=[]
for name, source in workloads.items():
    f=a.out/(name+'.js'); f.write_text(source); files.append(f)
if a.controls:
    files += sorted(Path('benchmarks').glob('bench_*.js'))
    files += sorted(Path('benchmarks/es6').glob('bench_*.js'))
results=[]
for f in files:
    if not fnmatch.fnmatch(f.stem, a.only): continue
    samples=[[],[]]; outputs=[set(),set()]; rss=[[],[]]
    for pair in range(-1,a.pairs):
        order=[0,1] if pair%2==0 else [1,0]
        for which in order:
            start=time.perf_counter()
            r=subprocess.run(['/usr/bin/time','-l',str(binaries[which]),'--script',str(f.resolve())],capture_output=True,text=True,timeout=120)
            elapsed=time.perf_counter()-start
            if r.returncode: raise RuntimeError(f'{f}: {r.returncode}\n{r.stdout}\n{r.stderr}')
            if f in files[:len(workloads)] and r.stdout.strip()!='ok': raise RuntimeError('bad checksum output')
            if pair>=0:
                samples[which].append(elapsed); outputs[which].add(r.stdout)
                for line in r.stderr.splitlines():
                    if 'maximum resident set size' in line: rss[which].append(int(line.split()[0]))
    # Date and regexp fixtures print timings; compare their remaining output.
    normalized = [{re.sub(r'\b\d+(?:\.\d+)? ms\b', '<time> ms', o)
                   if f.stem in ('bench_date', 'bench_regexp') else o
                   for o in side} for side in outputs]
    if normalized[0] != normalized[1]:
        raise RuntimeError(f'{f}: baseline/candidate output mismatch')
    med=[statistics.median(v) for v in samples]
    row={'name':f.stem,'seconds':samples,'median':med,'change_percent':100*(med[1]/med[0]-1),'rss':rss,'outputs':[sorted(v) for v in outputs]}
    results.append(row)
    (a.out/'results.json').write_text(json.dumps(results,indent=2))
    print(f'{f.stem}: {med[0]:.4f} -> {med[1]:.4f}s ({row["change_percent"]:+.1f}%)',flush=True)
