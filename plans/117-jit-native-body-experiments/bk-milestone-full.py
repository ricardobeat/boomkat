import subprocess,pathlib,time,json
rows=[]
for pair in range(2):
 for mode in (['before','after'] if pair==0 else ['after','before']):
  binary='/tmp/boomkat-ssa-repair/numeric/boomkat' if mode=='before' else '/tmp/bk-milestone/boomkat'
  path=pathlib.Path('/tmp/bk-milestone-full-'+str(pair)+'-'+mode+'.txt')
  print('START',pair,mode,flush=True);start=time.monotonic()
  with path.open('w') as f:p=subprocess.run([binary,'--jit','--script','/tmp/boomkat-jit-next/octane-full.js'],stdout=f,stderr=subprocess.STDOUT,timeout=600)
  row=dict(pair=pair,mode=mode,rc=p.returncode,seconds=time.monotonic()-start,log=str(path));rows.append(row)
  print(row,flush=True);print(path.read_text()[-500:],flush=True)
  pathlib.Path('/tmp/bk-milestone-full.json').write_text(json.dumps(rows,indent=2))
  assert p.returncode==0,row
