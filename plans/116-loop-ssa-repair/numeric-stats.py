import subprocess,pathlib,re,json
root=pathlib.Path('/tmp/boomkat-ssa-repair');rows=[]
for f in sorted(pathlib.Path('test').glob('sljit_ssa_*.js'))+[root/'cfg-corpus.js']+sorted(pathlib.Path('bench/mini').glob('*.js')):
 p=subprocess.run([str(root/'numeric-diag/boomkat'),'--jit','--stats','--script',str(f)],capture_output=True,text=True,timeout=120)
 log=p.stdout+p.stderr
 (root/(f.stem+'-numeric-stats.txt')).write_text(log)
 assert p.returncode==0,(f,p.stderr[-1000:])
 lines=[s for s in log.splitlines() if s.startswith('SLJIT ssa ')]
 hits=sum(int(m) for l in lines for m in re.findall(r'hits=(\d+)',l))
 iters=sum(int(m) for l in lines for m in re.findall(r'iterations=(\d+)',l))
 print(f,hits,iters,flush=True)
 if 'sljit_ssa_' in f.name: assert hits>0,f
 rows.append(dict(file=str(f),hits=hits,iterations=iters))
(root/'numeric-stats.json').write_text(json.dumps(rows,indent=2))
