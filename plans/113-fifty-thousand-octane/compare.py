import subprocess,json,time,re
from pathlib import Path
p=Path('/tmp/boomkat-jit-50k');rows=[]
commands=[('jsc',['/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc',str(p/'octane-jsc.js')]),('baseline',['/tmp/boomkat-jit-workflows/selected/boomkat','--jit','--stats','--script','/tmp/boomkat-jit-next/octane-full.js']),('large',[str(p/'large/boomkat'),'--jit','--stats','--script','/tmp/boomkat-jit-next/octane-full.js']),('reclaim',[str(p/'reclaim/boomkat'),'--jit','--stats','--script','/tmp/boomkat-jit-next/octane-full.js'])]
for mode,cmd in commands:
 print('start',mode,flush=True);start=time.monotonic()
 r=subprocess.run(cmd,capture_output=True,text=True,timeout=900)
 (p/(mode+'-full.txt')).write_text(r.stdout+r.stderr)
 scores=dict((name,int(value)) for name,value in re.findall(r'^([^:\n]+): (\d+)$',r.stdout,re.M))
 rows.append(dict(mode=mode,cmd=cmd,status=r.returncode,wall=time.monotonic()-start,scores=scores))
 (p/'comparison.json').write_text(json.dumps(rows,indent=2))
 print(mode, r.returncode, scores,flush=True)
 if r.returncode:print(r.stderr[-2000:],flush=True)
