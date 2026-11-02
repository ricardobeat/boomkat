import json,re,statistics,subprocess,time,sys,hashlib
from pathlib import Path
R=Path('/private/tmp/bk-minis-main-rat-6sgez9zo')
OUT=Path(sys.argv[2]);OUT.mkdir(parents=True,exist_ok=True)
configs={'b85-jit':[str(R/'b85-bin/boomkat'),'--jit'],'broken-jit':[str(R/'rat-bin/boomkat'),'--jit'],'candidate':[sys.argv[1],'--jit']}
rows=[]
for pair in range(3):
 for case in ['navier-stokes','gbemu','box2d','navier-original']:
  path=R/'navier-stokes-original-runner.js' if case=='navier-original' else R/'rat/bench/mini'/f'{case}.js'
  names=list(configs) if pair%2==0 else list(reversed(configs))
  for name in names:
   start=time.perf_counter();p=subprocess.run([*configs[name],'--script',str(path)],capture_output=True,text=True,timeout=120,cwd=R/'rat')
   found=re.fullmatch(r'[^:]+:\s+([\d.]+)(?: ms)?\s*',p.stdout)
   row={'pair':pair,'case':case,'config':name,'status':p.returncode,'wall_seconds':time.perf_counter()-start,'value':float(found[1]) if found else None,'stdout':p.stdout,'stderr':p.stderr}
   rows.append(row);(OUT/'raw.json').write_text(json.dumps(rows,indent=2))
   print(pair+1,case,name,row['value'],row['status'],flush=True)
summary={}
for case in ['navier-stokes','gbemu','box2d','navier-original']:
 summary[case]={name:statistics.median(r['value'] for r in rows if r['case']==case and r['config']==name) for name in configs}
(OUT/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary,indent=2),flush=True)
assert all(r['status']==0 and r['value'] is not None for r in rows)
