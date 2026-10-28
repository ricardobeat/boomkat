import subprocess,pathlib,time,json,re,sys
source=pathlib.Path('/tmp/boomkat-jit-next/octane-full.js');rows=[]
variants={'fix':'/tmp/bk-par-fix-isolated/boomkat','winner':'/tmp/bk-par-winner/boomkat','reserve':'/tmp/bk-par-winner-reserve/boomkat'}
# A screen first; retain complete per-suite output and every failed assertion.
for name in sys.argv[1:] or variants:
 path=pathlib.Path('/tmp/bk-par-full-'+str(len(rows))+'-'+name+'.txt')
 print('START',name,flush=True);t=time.monotonic()
 with path.open('w') as out:p=subprocess.run([variants[name],'--jit','--script',str(source)],stdout=out,stderr=subprocess.STDOUT,timeout=600)
 text=path.read_text();scores={k:float(v) for k,v in re.findall(r'^([^\n:]+):\s*([\d.]+)\s*$',text,re.M)}
 m=re.search(r'Score \(version \d+\):\s*([\d.]+)',text)
 row=dict(name=name,rc=p.returncode,seconds=time.monotonic()-t,scores=scores,score=float(m[1]) if m else None,log=str(path));rows.append(row)
 pathlib.Path('/tmp/bk-par-full.json').write_text(json.dumps(rows,indent=2));print(row,flush=True)
 if p.returncode or not m or 'Error' in text:raise SystemExit('full suite validation failed: '+str(path))
