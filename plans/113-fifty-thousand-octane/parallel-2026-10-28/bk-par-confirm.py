import subprocess,pathlib,re,json,time,statistics,hashlib
source=pathlib.Path('/tmp/boomkat-jit-next/octane-full.js');rows=[]
for pair in range(3):
 for name in (['fix','minimal'] if pair%2==0 else ['minimal','fix']):
  binary={'fix':'/tmp/bk-par-fix-isolated/boomkat','minimal':'/tmp/bk-par-minimal/boomkat'}[name]
  path=pathlib.Path(f'/tmp/bk-par-confirm-{pair}-{name}.txt');print('START',pair,name,flush=True);start=time.monotonic()
  with path.open('w') as out:p=subprocess.run([binary,'--jit','--stats','--script',str(source)],stdout=out,stderr=subprocess.STDOUT,timeout=600)
  s=path.read_text();scores={k:float(v) for k,v in re.findall(r'^([^\n:]+):\s*([\d.]+)\s*$',s,re.M)};m=re.search(r'Score \(version \d+\):\s*([\d.]+)',s)
  budget=re.search(r'SLJIT budget bytes=(\d+) limit=(\d+) native_work=(\d+) evictions=(\d+)',s)
  totals=re.search(r'SLJIT totals functions=(\d+) loops=(\d+) templates=(\d+)(?: hits=\d+)? code_bytes=(\d+)',s)
  row=dict(pair=pair,name=name,rc=p.returncode,seconds=time.monotonic()-start,scores=scores,score=float(m[1]) if m else None,budget=list(map(int,budget.groups())) if budget else None,totals=list(map(int,totals.groups())) if totals else None,log=str(path));rows.append(row)
  pathlib.Path('/tmp/bk-par-confirm.json').write_text(json.dumps(rows,indent=2));print(row,flush=True)
  if p.returncode or not m:raise SystemExit('full-suite assertion failure')
print('MEDIANS',{n:statistics.median(r['score'] for r in rows if r['name']==n) for n in ['fix','minimal']},flush=True)
