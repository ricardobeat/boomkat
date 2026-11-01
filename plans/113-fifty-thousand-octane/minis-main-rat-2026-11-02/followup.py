import subprocess,time,json,re,hashlib,statistics
from pathlib import Path
R=Path(__file__).resolve().parent
configs={'old-jit':[str(R/'b85-bin'/'boomkat'),'--jit'],'rat-jit':[str(R/'rat-bin'/'boomkat'),'--jit'],'rat-interpreter':[str(R/'rat-bin'/'boomkat')]}
rows=[]
def run(case,config,pair,source):
 start=time.perf_counter()
 p=subprocess.run(['/usr/bin/time','-l',*configs[config],'--script',str(source)],capture_output=True,text=True,timeout=180,cwd=R/'rat')
 row=dict(case=case,config=config,pair=pair,status=p.returncode,wall_seconds=time.perf_counter()-start,stdout=p.stdout,stderr=p.stderr)
 rows.append(row);(R/'followup-raw.json').write_text(json.dumps(rows,indent=2))
 print(case,config,pair,p.returncode,repr(p.stdout),round(row['wall_seconds'],2),flush=True)
for pair in range(3):
 order=list(configs) if pair%2==0 else list(reversed(configs))
 for case in ['navier-stokes','gbemu','box2d']:
  for c in order:run(case,c,pair,R/'rat'/'bench'/'mini'/f'{case}.js')
 for c in order:run('navier-original-runner',c,pair,R/'navier-stokes-original-runner.js')
print('DONE',flush=True)
