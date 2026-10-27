import subprocess,json,re,statistics
from pathlib import Path
p=Path('/tmp/boomkat-ssa-repair');rows=[]
bins={'baseline':'/tmp/boomkat-jit-workflows/selected/boomkat','ssa':str(p/'numeric/boomkat')}
for repeat in range(3):
 for f in sorted(Path('bench/mini').glob('*.js')):
  for mode in (['baseline','ssa'] if repeat%2==0 else ['ssa','baseline']):
   r=subprocess.run([bins[mode],'--jit','--script',str(f)],capture_output=True,text=True,timeout=180)
   (p/f'numeric-mini-{f.stem}-{mode}-{repeat}.txt').write_text(r.stdout+r.stderr)
   assert r.returncode==0,(f,mode,r.stdout,r.stderr)
   phases={n:int(ms) for n,ms in re.findall(r'^(.+): (\d+) ms$',r.stdout,re.M)}
   assert phases,(f,r.stdout)
   rows.append(dict(bench=f.stem,mode=mode,repeat=repeat,phases=phases));(p/'numeric-mini-pairs.json').write_text(json.dumps(rows,indent=2))
  print(repeat,f.stem,rows[-2]['phases'],rows[-1]['phases'],flush=True)
for name in sorted({r['bench'] for r in rows}):
 med={m:statistics.median(sum(r['phases'].values()) for r in rows if r['bench']==name and r['mode']==m) for m in bins}
 print(name,med,round(100*(med['ssa']/med['baseline']-1),1),flush=True)
for repeat in range(3):
 for mode in (['baseline','ssa'] if repeat%2==0 else ['ssa','baseline']):
  path=p/f'numeric-full-{mode}-{repeat}.txt'
  with path.open('w') as log:
   r=subprocess.run([bins[mode],'--jit','--script','/tmp/boomkat-jit-next/octane-full.js'],stdout=log,stderr=subprocess.STDOUT,text=True,timeout=600)
  output=path.read_text()
  print('FULL',repeat,mode,r.returncode,output,flush=True)
  assert r.returncode==0 and 'Score (version 9):' in output,(mode,output)
