from pathlib import Path
import subprocess,json,statistics
root=Path(__file__).resolve().parents[2];d=Path(__file__).resolve().parent;rows=[]
for mode in ['lexical','var','local','lexical_let_loop']:
 for n in [10000,20000,40000]:
  core=f'var start=Date.now();\n{("let" if mode.startswith("lexical") else "var")} s="";\nfor(var i=0;i<{n};i++)s+="abcde";\nvar elapsed=Date.now()-start;\nvar consumed=s.charCodeAt(s.length-1)+s.length;\nprint(elapsed+":"+consumed);'
  if mode=='lexical_let_loop':core=core.replace('for(var i=', 'for(let i=')
  if mode=='local':core='function build(){\n'+core+'\n}build();'
  path=d/f'string-{mode}-{n}.js';path.write_text(core)
  for repeat in range(-1,3):
   for engine in (['boomkat','qjs'] if repeat%2==0 else ['qjs','boomkat']):
    r=subprocess.run([str(root/'out'/engine),'--script',str(path)],capture_output=True,text=True,timeout=20);assert r.returncode==0,r.stderr
    elapsed,check=map(int,r.stdout.strip().split(':'));assert check==n*5+101
    if repeat>=0:rows.append(dict(mode=mode,n=n,engine=engine,repeat=repeat,ms=elapsed,checksum=check))
  print(mode,n,{engine:statistics.median(r['ms'] for r in rows if r['mode']==mode and r['n']==n and r['engine']==engine) for engine in ['boomkat','qjs']},flush=True)
(d/'string-results.json').write_text(json.dumps(rows,indent=2))
