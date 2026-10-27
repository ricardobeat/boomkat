import subprocess,json,re,statistics
from pathlib import Path
p=Path('/tmp/boomkat-jit-workflows');rows=[]
for repeat in range(3):
 for name in ['richards','deltablue','splay','gbemu','navier-stokes','mandreel','zlib','typescript','pdfjs','raytrace','crypto','earley-boyer','box2d']:
  for mode in (['baseline','selected'] if repeat%2==0 else ['selected','baseline']):
   binary=p/'baseline' if mode=='baseline' else p/mode/'boomkat'
   r=subprocess.run([str(binary),'--jit','--script',f'bench/mini/{name}.js'],capture_output=True,text=True,timeout=120)
   assert r.returncode==0,(name,mode,r.stdout,r.stderr)
   phases={n:int(ms) for n,ms in re.findall(r'^(.+): (\d+) ms$',r.stdout,re.M)}
   rows.append(dict(bench=name,mode=mode,repeat=repeat,phases=phases));(p/'selected-pairs.json').write_text(json.dumps(rows,indent=2))
  print(repeat,name,rows[-2]['phases'],rows[-1]['phases'],flush=True)
for name in sorted({r['bench'] for r in rows}):
 med={m:statistics.median(sum(r['phases'].values()) for r in rows if r['bench']==name and r['mode']==m) for m in ['baseline','selected']}
 print(name,med,round(100*(med['selected']/med['baseline']-1),1),flush=True)
