from pathlib import Path
import subprocess,time,json,statistics,os,hashlib
import argparse
p=argparse.ArgumentParser();p.add_argument('--baseline',required=True,type=Path);p.add_argument('--out',required=True,type=Path);args=p.parse_args()
root=Path(__file__).resolve().parents[3];base=args.out.resolve();base.mkdir(parents=True,exist_ok=True)
bins={'baseline':args.baseline.resolve(),'candidate':root/'out/boomkat','quickjs':root/'out/qjs'};rows=[]
cases={}
for name in ['append-10000','append-20000','append-40000','append-80000','wide-8','wide-64','wide-192']:
 cases[name]=Path(__file__).parent/(name+'.js')
cases['forof']=root/'benchmarks/es6/bench_forof.js';cases['class']=root/'benchmarks/es6/bench_class.js'
scene=base/'scene-100000.js';scene.write_text('var SCENE_NODES_OVERRIDE=100000;var SCENE_FRAMES_OVERRIDE=3000;\n'+(root/'benchmarks/bench_scene_churn.js').read_text()+'\nif(totalChanges!==FRAMES*VIEW_SIZE || prev.items.length!==VIEW_SIZE)throw Error("scene checksum");')
cases['scene-100000']=scene

for case,path in cases.items():
 for rep in range(-1,5):
  ns=list(bins);ns=ns[rep%3:]+ns[:rep%3]
  if rep%2:ns.reverse()
  for n in ns:
   with (base/'child.out').open('w') as o,(base/'child.err').open('w') as e:
    t=time.perf_counter();p=subprocess.Popen([str(bins[n]),'--script',str(path)],stdout=o,stderr=e);_,status,usage=os.wait4(p.pid,0);p.returncode=os.waitstatus_to_exitcode(status);wall=time.perf_counter()-t
   text=(base/'child.out').read_text();err=(base/'child.err').read_text()
   if p.returncode or 'FAIL' in text:raise RuntimeError((n,case,text,err))
   if rep>=0:rows.append(dict(case=case,variant=n,rep=rep,wall=wall,rss=usage.ru_maxrss,stdout=text))
 (base/'results.json').write_text(json.dumps(rows,indent=2))
 print(case,{n:round(statistics.median(x['wall'] for x in rows if x['case']==case and x['variant']==n)*1000,3) for n in bins},flush=True)
(base/'binaries.json').write_text(json.dumps({n:hashlib.sha256(p.read_bytes()).hexdigest() for n,p in bins.items()},indent=2))
