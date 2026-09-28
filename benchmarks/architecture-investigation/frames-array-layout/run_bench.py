from pathlib import Path
import subprocess,time,json,statistics,os,math,hashlib
import argparse
parser=argparse.ArgumentParser();parser.add_argument('--work-dir',type=Path,required=True);parser.add_argument('--skip-deep',action='store_true');args=parser.parse_args()
root=Path(__file__).resolve().parents[3];base=args.work_dir.resolve();base.mkdir(parents=True,exist_ok=True);rows=[]
for depth in [0,32,128]:
 (base/f'callback-{depth}.js').write_bytes((Path(__file__).parent/f'callback-{depth}.js').read_bytes())
bins={n:base/n for n in ['baseline','frames','arrays','combined']};bins['quickjs']=root/'out/qjs'
cases={f'callback-{n}':base/f'callback-{n}.js' for n in ([0] if args.skip_deep else [0,32,128])}
for n in ['bench_function_call','es6/bench_class','es6/bench_forof','es6/bench_destructuring','es6/bench_closure_capture','bench_string']:
 cases[n]=root/'benchmarks'/f'{n}.js'
source=(root/'benchmarks/bench_scene_churn.js').read_text()
for nodes,frames in [(10000,300),(100000,3000)]:
 p=base/f'scene-{nodes}.js';p.write_text(f'var SCENE_NODES_OVERRIDE={nodes};var SCENE_FRAMES_OVERRIDE={frames};\n'+source+'\nif(totalChanges!==FRAMES*VIEW_SIZE || prev.items.length!==VIEW_SIZE)throw Error("scene checksum");');cases[p.stem]=p
# Retained objects make header/storage differences visible after construction.
p=base/'retained-arrays.js';p.write_text('var all=[];for(var i=0;i<200000;i++)all.push([i,i+1,i+2]);var sum=0;for(var i=0;i<all.length;i++)sum+=all[i][0];if(sum!==19999900000)throw Error("sum");print("CHECK "+sum);');cases[p.stem]=p
p=base/'named-arrays.js';p.write_text('var all=[];for(var i=0;i<100000;i++){var a=[i,i+1];a.name="entry";a.tag=i;all.push(a);}var sum=0;for(var i=0;i<all.length;i++)sum+=all[i].tag+all[i][0];if(sum!==9999900000)throw Error("sum");print("CHECK "+sum);');cases[p.stem]=p

def run(binary,path):
 out=base/'child.out';err=base/'child.err'
 with out.open('w') as o,err.open('w') as e:
  start=time.perf_counter();p=subprocess.Popen([str(binary),'--script',str(path)],stdout=o,stderr=e)
  _,status,usage=os.wait4(p.pid,0);p.returncode=os.waitstatus_to_exitcode(status);wall=time.perf_counter()-start
 text=out.read_text();error=err.read_text()
 if p.returncode or 'FAIL' in text or 'Error:' in error:raise RuntimeError((binary,path,p.returncode,text,error))
 return wall,usage.ru_maxrss,text
for case,path in cases.items():
 for rep in range(-1,5):
  names=list(bins);names=names[rep%len(names):]+names[:rep%len(names)]
  if rep%2:names.reverse()
  for name in names:
   wall,rss,text=run(bins[name],path)
   if rep>=0:rows.append(dict(case=case,variant=name,rep=rep,wall=wall,rss=rss,stdout=text))
 (base/'results.json').write_text(json.dumps(rows,indent=2))
 print('SUMMARY',case,{n:round(statistics.median(r['wall'] for r in rows if r['case']==case and r['variant']==n)*1000,3) for n in bins},flush=True)
# Identical clock hook in before/after; native performance.now in QuickJS.
frames_rows=[]
source=source.replace('Date.now()','benchNow()').replace('var start = benchNow();','var samples=[];var start = benchNow();').replace('    if (dt > worst)', '    samples.push(dt);\n    if (dt > worst)')
source+='\nif(totalChanges!==FRAMES*VIEW_SIZE)throw Error("scene checksum");print("METRICS "+JSON.stringify(samples));'
for nodes,frames in [(10000,300),(100000,3000)]:
 variants={'baseline':base/'baseline-clock','combined':base/'combined-clock','quickjs':bins['quickjs']}
 for rep in range(-1,5):
  names=list(variants);names=names[rep%3:]+names[:rep%3]
  if rep%2:names.reverse()
  for name in names:
   p=base/f'scene-clock-{nodes}-{name}.js'
   pre='function benchNow(){return performance.now();}\n' if name=='quickjs' else 'function benchNow(){return Date.now("__benchmark_monotonic");}\n'
   p.write_text(pre+f'var SCENE_NODES_OVERRIDE={nodes};var SCENE_FRAMES_OVERRIDE={frames};\n'+source)
   wall,rss,text=run(variants[name],p);data=json.loads(next(x[8:] for x in text.splitlines() if x.startswith('METRICS ')));assert len(data)==frames
   if rep>=0:
    ordered=sorted(data);frames_rows.append(dict(nodes=nodes,variant=name,rep=rep,wall=wall,rss=rss,p50=ordered[math.ceil(frames*.5)-1],p99=ordered[math.ceil(frames*.99)-1],maximum=max(data),frames=data))
 (base/'frames.json').write_text(json.dumps(frames_rows,indent=2))
 print('LATENCY',nodes,{n:{k:round(statistics.median(r[k] for r in frames_rows if r['nodes']==nodes and r['variant']==n),4) for k in ['p50','p99','maximum']} for n in variants},flush=True)
(base/'binaries.json').write_text(json.dumps({n:hashlib.sha256(p.read_bytes()).hexdigest() for n,p in bins.items()},indent=2))
