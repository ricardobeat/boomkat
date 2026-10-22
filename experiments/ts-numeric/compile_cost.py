#!/usr/bin/env python3
"""Compile-only timing, max RSS, and instruction counts for a synthetic corpus."""
import json,pathlib,random,re,statistics,subprocess,sys
HERE=pathlib.Path(__file__).resolve().parent
ROOT=HERE.parents[1]
gen=HERE/'generated';gen.mkdir(exist_ok=True)
path=gen/'compile-corpus.ts'
path.write_text('\n'.join(f'function f{i}(a:number,b:number,c:number,d:number) {{ return (a*b+c)/(d-a)+b*c-a*d; }}' for i in range(3000)))
results=[]
jobs=[mode for mode in ['off','annotations','infer'] for _ in range(9)]
random.Random(1927).shuffle(jobs)
for mode in jobs:
 worker='import subprocess,resource,json,sys; p=subprocess.run(sys.argv[1:],text=True,capture_output=True,check=True); print(json.dumps(dict(output=p.stdout,rss=resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)))'
 p=subprocess.run([sys.executable,'-c',worker,str(ROOT/'out/boomkat_debug'),'--numeric-specialization='+mode,'--check','-d',str(path)],capture_output=True,text=True,check=True)
 measured=json.loads(p.stdout)
 results.append(dict(mode=mode,compile_us=int(re.search(r'compile:\s+(\d+) us',measured['output'])[1]),max_rss_bytes=measured['rss']))
counts={}
for mode in ['off','annotations','infer']:
 p=subprocess.run([str(ROOT/'out/boomkat_debug'),'--numeric-specialization='+mode,'-c',str(path)],capture_output=True,text=True,check=True)
 counts[mode]=dict(instructions=len(re.findall(r'^\[',p.stdout,re.M)),regions=p.stdout.count('NUMERIC_REGION'))
(HERE/'compile-results.json').write_text(json.dumps(dict(functions=3000,source_bytes=path.stat().st_size,results=results,counts=counts),indent=2)+'\n')
for mode in ['off','annotations','infer']:
 rows=[r for r in results if r['mode']==mode]
 print(mode,'compile_us',statistics.median(r['compile_us'] for r in rows),'max_rss_bytes',statistics.median(r['max_rss_bytes'] for r in rows),counts[mode])
