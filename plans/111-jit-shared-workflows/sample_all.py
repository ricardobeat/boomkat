from pathlib import Path
import subprocess,time,re,json,sys,pty,os,threading,queue
root=Path('/Users/rtomasi/cousas/boomkat/.worktrees/rat')
p=Path('/tmp/boomkat-jit-common')
sys.path.insert(0,str(root/'scripts'))
from profile_sljit_sample import attribute
summary=[]
for script in sorted(p.glob('*-long.js')):
 bench=script.name[:-8]; log=p/f'{bench}-map.txt'; samples=[]; phases=queue.Queue()
 master,slave=pty.openpty()
 child=subprocess.Popen([str(p/'map/boomkat'),'--jit','--stats','--script',str(script)],cwd=root,stdout=slave,stderr=slave,stdin=subprocess.DEVNULL)
 os.close(slave)
 def drain():
  pending=''
  with log.open('w') as out:
   while True:
    try:data=os.read(master,65536)
    except OSError:break
    if not data:break
    chunk=data.decode(errors='replace').replace('\r','');out.write(chunk);out.flush();pending+=chunk
    lines=pending.split('\n');pending=lines.pop()
    for line in lines:
     if line.startswith('PROFILE_RUN '):phases.put(line[len('PROFILE_RUN '):])
  os.close(master)
 reader=threading.Thread(target=drain);reader.start();start=time.monotonic()
 while reader.is_alive() or not phases.empty():
  try:phase=phases.get(timeout=.1)
  except queue.Empty:
   if time.monotonic()-start>150:child.kill();raise RuntimeError('profile timeout '+bench)
   continue
  time.sleep(.6)
  dest=p/f'{bench}-{phase}-sample.txt'
  r=subprocess.run(['/usr/bin/sample',str(child.pid),'3','-file',str(dest)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=20)
  samples.append((phase,dest,r.returncode));print('sample',bench,phase,r.returncode,flush=True)
 child.wait();reader.join()
 for phase,dest,rc in samples:
  row=dict(bench=bench,phase=phase,rc=child.returncode,sample_rc=rc,wall=time.monotonic()-start)
  if rc==0:row.update(attribute(log.read_text(),dest.read_text()))
  summary.append(row)
 (p/'sample-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
 print('complete',bench,'rc',child.returncode,'samples',len(samples),flush=True)
