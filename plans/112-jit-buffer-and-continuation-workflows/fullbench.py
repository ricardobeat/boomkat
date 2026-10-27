import subprocess,json,re,statistics,time
from pathlib import Path
p=Path('/tmp/boomkat-jit-workflows'); rows=[]
for mode in ['baseline','selected']:
 binary=p/'baseline' if mode=='baseline' else p/'selected/boomkat'
 start=time.monotonic()
 r=subprocess.run([str(binary),'--jit','--script','/tmp/boomkat-jit-next/octane-full.js'],capture_output=True,text=True,timeout=900)
 (p/('octane-'+mode+'.txt')).write_text(r.stdout+r.stderr)
 rows.append(dict(mode=mode,status=r.returncode,seconds=time.monotonic()-start,stdout=r.stdout,stderr=r.stderr))
 (p/'octane-results.json').write_text(json.dumps(rows,indent=2))
 print(mode,r.returncode,r.stdout,flush=True)
 assert r.returncode==0
for mode in ['baseline','selected']:
 binary=p/'baseline' if mode=='baseline' else p/'selected/boomkat'
 for name in ['test/jit_kernel_links.js','test/jit_read_miss_cache.js','test/jit_string_continuations.js']:
  r=subprocess.run([str(binary),'--jit','--jit-stress','--script',name],capture_output=True,text=True)
  assert r.returncode==0,(mode,name,r.stdout,r.stderr)
