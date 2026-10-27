from pathlib import Path
import subprocess,time,re,json,sys,pty,os,threading,queue
root=Path('/Users/rtomasi/cousas/boomkat/.worktrees/rat');p=Path('/tmp/boomkat-jit-50k')
sys.path.insert(0,str(root/'scripts'))
from profile_sljit_sample import attribute
master,slave=pty.openpty();phases=queue.Queue();samples=[];current=['startup'];events=[]
child=subprocess.Popen([str(p/'map/boomkat'),'--jit','--stats','--script',str(p/'octane-profile.js')],cwd=root,stdout=slave,stderr=slave,stdin=subprocess.DEVNULL)
os.close(slave)
def drain():
 pending=''
 with (p/'full-map.txt').open('w') as out:
  while True:
   try:data=os.read(master,65536)
   except OSError:break
   if not data:break
   chunk=data.decode(errors='replace').replace('\r','');out.write(chunk);out.flush();pending+=chunk
   lines=pending.split('\n');pending=lines.pop()
   for line in lines:
    if line.startswith('PROFILE_RUN '):
     name=line[len('PROFILE_RUN '):];current[0]=name;events.append((time.monotonic(),name));phases.put(name)
 os.close(master)
reader=threading.Thread(target=drain);reader.start();start=time.monotonic()
while reader.is_alive() or not phases.empty():
 try:phase=phases.get(timeout=.1)
 except queue.Empty:
  if time.monotonic()-start>900:child.kill();raise RuntimeError('timeout')
  continue
 if phase != current[0]: continue
 time.sleep(.2)
 if phase != current[0]: continue
 dest=p/(phase+'-sample.txt');sample_start=time.monotonic()
 r=subprocess.run(['/usr/bin/sample',str(child.pid),'1','-file',str(dest)],capture_output=True,text=True,timeout=20)
 valid=current[0]==phase;samples.append((phase,dest,r.returncode,valid,sample_start,time.monotonic()));print('sample',phase,r.returncode,'same_phase',valid,flush=True)
child.wait();reader.join();summary=[]
for phase,dest,rc,valid,start,end in samples:
 row=dict(bench=phase,rc=child.returncode,sample_rc=rc,same_phase=valid,start=start,end=end)
 if rc==0 and valid:row.update(attribute((p/'full-map.txt').read_text(),dest.read_text()))
 summary.append(row)
(p/'full-samples.json').write_text(json.dumps(summary,indent=2)+'\n')
(p/'phase-events.json').write_text(json.dumps(events,indent=2))
print('complete',child.returncode,flush=True)
