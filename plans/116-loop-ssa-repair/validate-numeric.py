import subprocess,pathlib,re,os,json
root=pathlib.Path('/tmp/boomkat-ssa-repair')
files=sorted(set(pathlib.Path('test').glob('sljit*.js'))|set(pathlib.Path('test').glob('jit*.js')))+[root/'cfg-corpus.js']
rows=[]
for f in files:
 outputs=[]
 for args in ([],['--jit'],['--jit','--jit-stress']):
  p=subprocess.run([str(root/'numeric/boomkat'),*args,'--script',str(f)],capture_output=True,text=True,timeout=90)
  assert p.returncode==0,(f,args,p.stdout,p.stderr)
  outputs.append(re.sub(r'\b\d+(?:\.\d+)? ms','N ms',p.stdout))
 assert len(set(outputs))==1,(f,outputs)
 print('PASS',f,flush=True);rows.append(str(f))
(root/'numeric-focused.json').write_text(json.dumps(rows,indent=2))
print('TOTAL',len(files),flush=True)
