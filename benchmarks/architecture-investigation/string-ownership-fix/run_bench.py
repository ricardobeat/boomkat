from pathlib import Path
import subprocess,json,statistics,time,os,re,hashlib,argparse
p=argparse.ArgumentParser();p.add_argument('--baseline',required=True,type=Path);p.add_argument('--out',type=Path,default=Path('/tmp/boomkat-string-bench'));args=p.parse_args()
root=Path(__file__).resolve().parents[3];base=args.out; base.mkdir(parents=True,exist_ok=True);rows=[]
binaries={'before':args.baseline.resolve(),'after':root/'out/boomkat','quickjs':root/'out/qjs'}
cases=[]
for mode in ['let','var']:
 for n in [10000,20000,40000,80000]:
  p=base/f'append-{mode}-{n}.js';p.write_text(f'var start=Date.now();let s="";for({mode} i=0;i<{n};i++)s+="abcde";var elapsed=Date.now()-start;if(s!=="abcde".repeat({n}))throw new Error("string mismatch");print("CHECK "+s.length);print("TIME "+elapsed);');cases.append((p.stem,p))
for name in ['bench_string','es6/bench_forof','es6/bench_template_literal','es6/bench_class','es6/bench_destructuring','es6/bench_closure_capture','bench_function_call','bench_loop']:
 cases.append((name,root/'benchmarks'/f'{name}.js'))
for nodes,frames in [(10000,300),(100000,3000)]:
 p=base/f'scene-{nodes}.js';p.write_text(f'var SCENE_NODES_OVERRIDE={nodes};var SCENE_FRAMES_OVERRIDE={frames};\n'+(root/'benchmarks/bench_scene_churn.js').read_text()+'\nprint("CHECK "+totalChanges+":"+prev.items[0].key+":"+scene.length);');cases.append((p.stem,p))
for label,path in cases:
 expected=None
 for repeat in range(-1,5):
  names=list(binaries);names=names[repeat%3:]+names[:repeat%3]
  if repeat%2:names.reverse()
  for name in names:
   with (base/'child.out').open('w') as stdout,(base/'child.err').open('w') as stderr:
    start=time.perf_counter();child=subprocess.Popen([str(binaries[name]),'--script',str(path)],stdout=stdout,stderr=stderr);pid,status,usage=os.wait4(child.pid,0);child.returncode=os.waitstatus_to_exitcode(status);wall=time.perf_counter()-start
   out=(base/'child.out').read_text();err=(base/'child.err').read_text()
   if child.returncode or 'FAIL' in out:raise RuntimeError((label,name,out,err))
   check=re.sub(r'TIME \d+','TIME <time>',out);check=re.sub(r'\b(total|worst_frame)=\d+ms',r'\1=<time>ms',check)
   if expected is None:expected=check
   if check!=expected:raise RuntimeError((label,name,check,expected))
   elapsed=re.search(r'TIME (\d+)',out);worst=re.search(r'worst_frame=(\d+)ms',out)
   if repeat>=0:
    rows.append(dict(case=label,engine=name,repeat=repeat,wall=wall,rss=usage.ru_maxrss,inner_ms=int(elapsed[1]) if elapsed else None,worst_frame_ms=int(worst[1]) if worst else None,stdout=out));(base/'results.json').write_text(json.dumps(rows,indent=2))
 group=[r for r in rows if r['case']==label]
 print(label,{n:{'wall':round(statistics.median(r['wall'] for r in group if r['engine']==n),5),'inner_ms':statistics.median(r['inner_ms'] for r in group if r['engine']==n) if group[0]['inner_ms'] is not None else None,'rss_mib':round(statistics.median(r['rss'] for r in group if r['engine']==n)/1048576,2)} for n in binaries},flush=True)
(base/'binaries.json').write_text(json.dumps({n:hashlib.sha256(p.read_bytes()).hexdigest() for n,p in binaries.items()},indent=2))
