import json,subprocess,statistics,time
from pathlib import Path
root=Path(__file__).resolve().parents[2];base=Path(__file__).resolve().parent;rows=[]
for file in ['class','forof']:
 expected=None
 for pair in range(-1,5):
  for name in (['boomkat','qjs'] if pair%2==0 else ['qjs','boomkat']):
   start=time.perf_counter();r=subprocess.run([str(root/'out'/name),'--script',str(base/(file+'.js'))],capture_output=True,text=True,timeout=30)
   if r.returncode:raise RuntimeError(r.stdout+r.stderr)
   check=next(x for x in r.stdout.splitlines() if x.startswith('CHECK'))
   if expected is None:expected=check
   if expected!=check:raise RuntimeError((expected,check))
   if pair>=0:
    phases={x[6:].rsplit(' ',1)[0]:int(x.rsplit(' ',1)[1]) for x in r.stdout.splitlines() if x.startswith('PHASE')}
    rows.append(dict(workload=file,engine=name,repeat=pair,wall=time.perf_counter()-start,phases_ms=phases,checksum=check))
 (base/'phase-results.json').write_text(json.dumps(rows,indent=2))
 group=[r for r in rows if r['workload']==file]
 for phase in group[0]['phases_ms']:
  values={n:statistics.median(r['phases_ms'][phase] for r in group if r['engine']==n) for n in ['boomkat','qjs']}
  print(file,phase,values,flush=True)
