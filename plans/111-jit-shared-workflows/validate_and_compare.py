from pathlib import Path
import subprocess,json,sys,hashlib,time,re,statistics
sys.path.insert(0,'scripts');from report_jit import parse
p=Path('/tmp/boomkat-jit-common');results=[]
fixtures=sorted(set(Path('test').glob('jit_*.js'))|set(Path('test').glob('sljit_*.js')))
for src in fixtures:
 expected=None
 for mode,flags in [('interp',[]),('jit',['--jit']),('stress',['--jit-stress'])]:
  r=subprocess.run([str(p/'diag/boomkat'),*flags,'--script',str(src)],capture_output=True,text=True,timeout=30)
  normalized=re.sub(r'\b\d+ ms\b', '<elapsed> ms', r.stdout)
  if expected is None:expected=normalized
  row=dict(test=str(src),mode=mode,rc=r.returncode,match=normalized==expected)
  results.append(row)
  if r.returncode or normalized!=expected:
   (p/'validation-failure.txt').write_text(r.stdout+r.stderr);raise RuntimeError(row)
(p/'validation.json').write_text(json.dumps(results,indent=2)+'\n');print('focused checks passed',len(results),flush=True)
for mode,names in [('diag',['mandreel','zlib','navier-stokes','gbemu']),('large-diag',['mandreel','zlib','navier-stokes','gbemu','box2d','typescript'])]:
 for name in names:
  log=p/f'{name}-{mode}-final.txt'
  with log.open('w') as out:r=subprocess.run([str(p/mode/'boomkat'),'--jit','--stats','--script',f'bench/mini/{name}.js'],stdout=out,stderr=subprocess.STDOUT,timeout=120)
  if r.returncode:raise RuntimeError((mode,name,r.returncode))
  report=parse(log.read_text());(p/f'{name}-{mode}-final.json').write_text(json.dumps(report,indent=2)+'\n')
  print(mode,name,report['totals'],flush=True)
rows=[]
for repeat in range(5):
 for name in ['mandreel','zlib','navier-stokes','gbemu','box2d','typescript']:
  if repeat>=3 and name in ['box2d','typescript']:continue
  for mode in (['large','guards'] if repeat%2==0 else ['guards','large']):
   start=time.monotonic();r=subprocess.run([str(p/mode/'boomkat'),'--jit','--script',f'bench/mini/{name}.js'],capture_output=True,text=True,timeout=180)
   row=dict(bench=name,repeat=repeat,mode=mode,rc=r.returncode,wall=time.monotonic()-start,phases={n:int(ms) for n,ms in re.findall(r'^(.+): (\d+) ms$',r.stdout,re.M)})
   (p/f'{name}-{mode}-guards-pair-{repeat}.txt').write_text(r.stdout+r.stderr)
   if r.returncode:raise RuntimeError(row)
   rows.append(row);(p/'guards-pairs.json').write_text(json.dumps(rows,indent=2)+'\n')
  print('pair',repeat,name,rows[-2]['phases'],rows[-1]['phases'],flush=True)
for name in sorted({r['bench'] for r in rows}):
 med={mode:statistics.median(sum(r['phases'].values()) for r in rows if r['bench']==name and r['mode']==mode) for mode in ['large','guards']}
 print('result',name,med,round(100*(med['guards']/med['large']-1),1),flush=True)
