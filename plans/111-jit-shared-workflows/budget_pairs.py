from pathlib import Path
import subprocess,time,re,json,statistics
p=Path('/tmp/boomkat-jit-common');rows=[]
benches=[s for s in sorted(Path('bench/mini').glob('*.js')) if s.stem not in ['richards','deltablue']]
for repeat in range(3):
 for src in benches:
  for mode in (['base','large'] if repeat%2==0 else ['large','base']):
   start=time.monotonic();r=subprocess.run([str(p/mode/'boomkat'),'--jit','--script',str(src)],capture_output=True,text=True,timeout=180)
   row=dict(bench=src.stem,repeat=repeat,mode=mode,rc=r.returncode,wall=time.monotonic()-start,phases={name:int(ms) for name,ms in re.findall(r'^(.+): (\d+) ms$',r.stdout,re.M)})
   (p/f'{src.stem}-{mode}-{repeat}.txt').write_text(r.stdout+r.stderr)
   if r.returncode:raise RuntimeError(row)
   rows.append(row);(p/'budget-pairs.json').write_text(json.dumps(rows,indent=2)+'\n')
  print(repeat,src.stem,rows[-2]['phases'],rows[-1]['phases'],flush=True)
for src in benches:
 med={mode:statistics.median(sum(r['phases'].values()) for r in rows if r['bench']==src.stem and r['mode']==mode) for mode in ['base','large']}
 print(src.stem,med,round((med['large']/med['base']-1)*100,1),flush=True)
