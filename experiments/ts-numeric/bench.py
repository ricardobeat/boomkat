#!/usr/bin/env python3
"""Focused, randomized, repeated region experiment. Never runs external suites."""
import argparse,json,pathlib,random,re,statistics,subprocess,time
ROOT=pathlib.Path(__file__).resolve().parents[2]
HERE=pathlib.Path(__file__).resolve().parent
GENERATED=HERE/'generated';GENERATED.mkdir(exist_ok=True)
CASES={
 'one-add-int': ('a+b', ['i&255','i&127']),
 'sum4-int': ('a+b+c+d', ['i&255','i&127','i&63','i&31']),
 'sum4-double': ('a+b+c+d', ['(i&255)+0.25','(i&127)+0.5','(i&63)+0.75','(i&31)+0.125']),
 'calc-int': ('(a*b+c)/(d-a)+b*c-a*d', ['(i&255)+1','(i&127)+2','(i&63)+3','(i&31)+0.5']),
 'calc-double': ('(a*b+c)/(d-a)+b*c-a*d', ['(i&255)+0.25','(i&127)+0.5','(i&63)+0.75','(i&31)+0.125']),
 'chain20-int': ('((a+b+c+d)*(a-b+c-d)/(a+b+c+d+1)+(a*b-c*d)+(b*c-d*a))', ['(i&255)+1','(i&127)+2','(i&63)+3','(i&31)+4']),
 'chain20-double': ('((a+b+c+d)*(a-b+c-d)/(a+b+c+d+1)+(a*b-c*d)+(b*c-d*a))', ['(i&255)+0.25','(i&127)+0.5','(i&63)+0.75','(i&31)+0.125']),
 'guard-fail-string': ('a+b+c+d', ['"x"','i&127','i&63','i&31']),
 'mixed-one-in-16': ('a+b+c+d', ['(i&15)===0?"x":i&255','i&127','i&63','i&31']),
}
def source(expr,args,n,typed):
 names=['a','b','c','d'][:len(args)]
 params=','.join(x+(': number' if typed else '') for x in names)
 # Stable final Number checksum; strings test their length. Warmup is outside timer.
 return f'''function kernel({params}) {{ return {expr}; }}
function run(n) {{ let checksum=0; for(let i=0;i<n;i++) {{ const x=kernel({','.join(args)}); checksum += typeof x === 'string' ? x.length : x; }} return checksum; }}
run(20000); const start=Date.now(); const checksum=run({n}); print(Date.now()-start,checksum);
'''
def save_results(path,iterations,runs,rows):
 lines=['{',f'  "iterations": {iterations},',f'  "runs": {runs},','  "results": [']
 lines += ['    '+json.dumps(row)+(',' if i+1<len(rows) else '') for i,row in enumerate(rows)]
 lines += ['  ]','}']
 path.write_text('\n'.join(lines)+'\n')
def main():
 p=argparse.ArgumentParser();p.add_argument('--runs',type=int,default=9);p.add_argument('--iterations',type=int,default=2000000);p.add_argument('--output',default='results.json');p.add_argument('--baseline');p.add_argument('--compact',action='store_true');a=p.parse_args()
 binary=str(ROOT/'out/boomkat');jobs=[]
 modes=[('generic-ts','off',True),('annotations-ts','annotations',True),('infer-js','infer',False)]
 if a.compact:modes.append(('compact-ts','annotations-compact',True))
 if a.baseline:modes.append(('baseline-ts',None,True))
 for case,(expr,args) in CASES.items():
  for label,mode,typed in modes:
   path=GENERATED/(case+('.ts' if typed else '.js'));path.write_text(source(expr,args,a.iterations,typed))
   for run in range(a.runs): jobs.append((case,label,mode,str(path),run))
 random.Random(1927).shuffle(jobs); results=[]
 for case,label,mode,path,run in jobs:
  cmd=[a.baseline if label=='baseline-ts' else binary]
  if mode:cmd.append('--numeric-specialization='+mode)
  cmd+=['--script',path]; start=time.perf_counter();r=subprocess.run(cmd,text=True,capture_output=True,check=True)
  fields=r.stdout.strip().split();results.append(dict(case=case,mode=label,run=run,milliseconds=float(fields[0]),checksum=fields[1],wall=time.perf_counter()-start))
 checks={}
 for row in results:checks.setdefault(row['case'],set()).add(row['checksum'])
 assert all(len(x)==1 for x in checks.values()),checks
 save_results(HERE/a.output,a.iterations,a.runs,results)
 for case in CASES:
  groups={mode:[x['milliseconds'] for x in results if x['case']==case and x['mode']==mode] for mode,_,_ in modes}
  print(case,' '.join(f'{mode}={statistics.median(xs):g}ms[{min(xs):g},{max(xs):g}]' for mode,xs in groups.items()),flush=True)
if __name__=='__main__':main()
