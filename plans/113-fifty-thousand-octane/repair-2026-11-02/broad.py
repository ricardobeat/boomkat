import subprocess,time,json,re,statistics,math,sys
from pathlib import Path
R=Path('/private/tmp/bk-minis-main-rat-6sgez9zo');O=Path(sys.argv[2]);O.mkdir(parents=True,exist_ok=True)
configs={'b85':str(R/'b85-bin/boomkat'),'fixed':sys.argv[1]}
cases=sorted(p.stem for p in (R/'rat/bench/mini').glob('*.js') if p.stem!='strings-intl');rows=[]
for pair in range(3):
 for i,case in enumerate(cases):
  order=list(configs) if (pair+i)%2==0 else list(reversed(configs))
  for name in order:
   start=time.perf_counter();p=subprocess.run([configs[name],'--jit','--script',str(R/'rat/bench/mini'/f'{case}.js')],capture_output=True,text=True,timeout=120,cwd=R/'rat')
   values=re.findall(r'^([^\n:]+): ([\d.]+) ms$',p.stdout,re.M)
   valid=p.returncode==0 and bool(values) and len(values)==len(p.stdout.strip().splitlines())
   row={'pair':pair,'case':case,'config':name,'status':p.returncode,'valid':valid,'ms':sum(float(x[1]) for x in values),'wall_seconds':time.perf_counter()-start,'stdout':p.stdout,'stderr':p.stderr}
   rows.append(row);(O/'raw.json').write_text(json.dumps(rows,indent=2));print(pair+1,case,name,row['ms'],valid,flush=True)
summary=[]
for case in cases:
 row={'case':case}
 for name in configs:row[name]=statistics.median(x['ms'] for x in rows if x['case']==case and x['config']==name)
 row['speedup']=row['b85']/row['fixed'];summary.append(row)
(O/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary,indent=2));assert all(x['valid'] for x in rows)
