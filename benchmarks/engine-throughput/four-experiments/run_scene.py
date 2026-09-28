from pathlib import Path
import subprocess,time,json,statistics,math,argparse,resource
p=argparse.ArgumentParser();p.add_argument('--variants',nargs='+',default=['baseline','mul','arrays','slots','clock64','clock128','quickjs']);p.add_argument('--runs',type=int,default=5);p.add_argument('--output',default='scene-results.json');a=p.parse_args()
base=Path(__import__('os').environ.get('BOOMKAT_EXPERIMENT_DIR', '/tmp/boomkat-four-experiments'));root=Path(__file__).resolve().parents[3];rows=[]
source=(root/'benchmarks/bench_scene_churn.js').read_text().replace('Date.now()','benchNow()')
source=source.replace('var start = benchNow();','var samples = new Float64Array(FRAMES);\nvar start = benchNow();').replace('    if (dt > worst)', '    samples[f] = dt;\n    if (dt > worst)')
source+='''
if (totalChanges !== FRAMES * VIEW_SIZE || prev.items.length !== VIEW_SIZE) throw new Error('scene count');
var checksum = 0;
for (var j=0;j<scene.length;j++) {
 var n=scene[j];
 if(n.id!==j || n.transform.length!==6 || typeof n.style.color!=='string' || !isFinite(n.transform[4])) throw new Error('node corruption');
 checksum += n.transform[4] + n.transform[5];
}
for(var j=0;j<prev.items.length;j++) {
 var item=prev.items[j];
 if(!isFinite(item.pos.x) || !isFinite(item.pos.y) || item.m.length!==6 || typeof item.label!=='string') throw new Error('view corruption');
 checksum += item.pos.x + item.pos.y + item.key;
}
var results=[];for(var j=0;j<FRAMES;j++)results.push(samples[j]);
print('METRICS '+JSON.stringify({frames:results,total:elapsed,check:[totalChanges,scene.length,checksum]}));
'''
def percentile(vals,p): return sorted(vals)[max(0,math.ceil(len(vals)*p)-1)]
for nodes,frames in [(10000,300),(100000,3000)]:
 files={}
 for n in a.variants:
  pre='function benchNow(){return performance.now();}\n' if n=='quickjs' else 'function benchNow(){return Date.now("__benchmark_monotonic");}\n'
  path=base/f'scene-{nodes}-{n}.js';path.write_text(pre+f'var SCENE_NODES_OVERRIDE={nodes};var SCENE_FRAMES_OVERRIDE={frames};\n'+source);files[n]=path
 expected=None
 for repeat in range(-1,a.runs):
  names=a.variants[repeat%len(a.variants):]+a.variants[:repeat%len(a.variants)]
  if repeat%2: names=names[::-1]
  for n in names:
   binary=root/'out/qjs' if n=='quickjs' else base/n/'out/boomkat'
   command=[str(binary),'--script',str(files[n])]
   # wait4 reports per-process peak RSS on macOS without the sandboxed time(1) sysctl.
   out=base/'child.stdout';err=base/'child.stderr'
   with out.open('w') as stdout,err.open('w') as stderr:
    t=time.perf_counter();child=subprocess.Popen(command,stdout=stdout,stderr=stderr);pid,status,usage=__import__('os').wait4(child.pid,0);child.returncode=__import__('os').waitstatus_to_exitcode(status);wall=time.perf_counter()-t
   text=out.read_text()
   if child.returncode or 'FAIL' in text: raise RuntimeError(n+' '+err.read_text()+text)
   data=json.loads(next(x[8:] for x in text.splitlines() if x.startswith('METRICS ')))
   if expected is None:expected=data['check']
   if data['check']!=expected:raise RuntimeError((n,data['check'],expected))
   if repeat>=0:
    f=data['frames'];row=dict(variant=n,nodes=nodes,repeat=repeat,wall=wall,rss=usage.ru_maxrss,total_ms=data['total'],p50=percentile(f,.50),p95=percentile(f,.95),p99=percentile(f,.99),maximum=max(f),frames=f,checksum=data['check']);rows.append(row)
    (base/a.output).write_text(json.dumps(rows,indent=2))
    print(f'{nodes} {repeat} {n}: wall={wall:.4f}s p95={row["p95"]:.3f} p99={row["p99"]:.3f} max={row["maximum"]:.3f}ms rss={usage.ru_maxrss/1048576:.1f}MiB',flush=True)
 for n in a.variants:
  group=[r for r in rows if r['nodes']==nodes and r['variant']==n]
  print('SUMMARY',nodes,n,{k:round(statistics.median(r[k] for r in group),4) for k in ['wall','total_ms','p50','p95','p99','maximum','rss']},flush=True)
