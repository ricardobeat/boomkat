import subprocess,json,re,statistics,pathlib
root=pathlib.Path('/Users/rtomasi/cousas/boomkat/.worktrees/rat');rows=[]
variants={'control':'/tmp/bk-par-control/boomkat','fix':'/tmp/bk-par-fix-isolated/boomkat','ssa':'/tmp/bk-par-ssa-isolated/boomkat','reads':'/tmp/bk-par-reads-isolated/boomkat'}
for bench in ['crypto','navier-stokes','raytrace','earley-boyer','splay','richards','deltablue','pdfjs','zlib','typescript','code-load']:
 for i in range(3):
  names=list(variants)
  if i%2:names.reverse()
  for name in names:
   p=subprocess.run([variants[name],'--jit','--script',str(root/f'bench/mini/{bench}.js')],capture_output=True,text=True,timeout=90)
   times=list(map(float,re.findall(r': (\d+(?:\.\d+)?) ms',p.stdout)))
   row=dict(bench=bench,variant=name,pair=i,ms=sum(times),rc=p.returncode,output=p.stdout,error=p.stderr);rows.append(row)
   pathlib.Path('/tmp/bk-par-screen.json').write_text(json.dumps(rows,indent=2))
   if p.returncode or not times: print('FAIL',row,flush=True);raise SystemExit(1)
 print(bench,{n:statistics.median(r['ms'] for r in rows if r['bench']==bench and r['variant']==n) for n in variants},flush=True)
