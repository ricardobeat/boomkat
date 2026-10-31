import subprocess,json,re,time
from pathlib import Path
rows=[]
for pair in range(3):
 for k in ([0,1] if pair%2==0 else [1,0]):
  mode=['control','candidate'][k]
  cmd=[['/tmp/bk-register-control-source/out/boomkat','out/boomkat'][k],'--jit','--stats','--script','/tmp/boomkat-jit-next/octane-full.js']
  print('start',pair,mode,flush=True);t=time.monotonic()
  r=subprocess.run(cmd,capture_output=True,text=True,timeout=900)
  Path(f'/tmp/bk-register-full-{pair}-{mode}.txt').write_text(r.stdout+r.stderr)
  scores={n:int(v) for n,v in re.findall(r'^([^:\n]+): (\d+)$',r.stdout,re.M)}
  rows.append(dict(pair=pair,mode=mode,command=cmd,status=r.returncode,wall=time.monotonic()-t,scores=scores))
  Path('/tmp/bk-register-full.json').write_text(json.dumps(rows,indent=2))
  print(mode,r.returncode,scores,flush=True)
  if r.returncode:raise SystemExit(1)
