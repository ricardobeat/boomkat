import os,sys,time,signal,re,json,hashlib
from pathlib import Path
base,candidate,out=sys.argv[1:4]
out=Path(out);out.mkdir(parents=True,exist_ok=True)
script='/tmp/bk-original-full-octane.js'
meta={'bundle_sha256':hashlib.sha256(Path(script).read_bytes()).hexdigest(),'binaries':{p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in [base,candidate]},'runs':[]}
for pair in range(3):
 for side in ([0,1] if pair%2==0 else [1,0]):
  binary=[base,candidate][side]; log=out/f'pair{pair+1}-{["baseline","candidate"][side]}.log'
  print('START',pair+1,side,flush=True)
  start=time.monotonic(); pid=os.fork()
  if pid==0:
   fd=os.open(log,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o644)
   os.dup2(fd,1);os.dup2(fd,2);os.close(fd)
   os.execv(binary,[binary,'--jit','--script',script])
  while True:
   done,status,usage=os.wait4(pid,os.WNOHANG)
   if done:break
   if time.monotonic()-start>1200:
    os.kill(pid,signal.SIGKILL);done,status,usage=os.wait4(pid,0);break
   time.sleep(.25)
  output=log.read_text(); score=re.search(r'Score \(version [^)]+\): (\d+)',output)
  row={'pair':pair+1,'side':['baseline','candidate'][side],'exit':os.waitstatus_to_exitcode(status),'seconds':time.monotonic()-start,'cpu_seconds':usage.ru_utime+usage.ru_stime,'maxrss_bytes':usage.ru_maxrss,'score':int(score[1]) if score else None,'log':log.name}
  meta['runs'].append(row);(out/'results.json').write_text(json.dumps(meta,indent=2)+'\n');print(row,flush=True)
  if row['exit'] or not score:sys.exit(1)
