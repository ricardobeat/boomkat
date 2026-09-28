from pathlib import Path
import json,subprocess,time,os,statistics
import argparse
p=argparse.ArgumentParser();p.add_argument('--work-dir',type=Path,required=True);args=p.parse_args()
root=Path(__file__).resolve().parents[3];base=args.work_dir.resolve();bins={n:base/n for n in ['baseline','combined','two-slots']};rows=[]
cases=['named-arrays','retained-arrays','scene-100000']
for props in [4,8]:
 p=base/f'named-{props}.js';p.write_text('var all=[];for(var i=0;i<100000;i++){var a=[i,i+1];'+''.join(f'a.p{j}=i;' for j in range(props))+'all.push(a);}var sum=0;for(var i=0;i<all.length;i++)sum+=all[i].p0+all[i][0];if(sum!==9999900000)throw Error("sum");print("CHECK "+sum);');cases.append(p.stem)
cases.append('forof');(base/'forof.js').write_text((root/'benchmarks/es6/bench_forof.js').read_text())
for case in cases:
 for rep in range(-1,5):
  ns=list(bins);ns=ns[rep%3:]+ns[:rep%3]
  if rep%2:ns.reverse()
  for n in ns:
   with (base/'slots.out').open('w') as o,(base/'slots.err').open('w') as e:
    t=time.perf_counter();p=subprocess.Popen([str(bins[n]),'--script',str(base/(case+'.js'))],stdout=o,stderr=e);_,s,u=os.wait4(p.pid,0);p.returncode=os.waitstatus_to_exitcode(s);wall=time.perf_counter()-t
   assert p.returncode==0,(n,case,(base/'slots.err').read_text())
   if rep>=0:rows.append(dict(case=case,variant=n,rep=rep,wall=wall,rss=u.ru_maxrss))
 print(case,{n:{k:round(statistics.median(x[k] for x in rows if x['case']==case and x['variant']==n),4) for k in ['wall','rss']} for n in bins},flush=True)
 (base/'slots-results.json').write_text(json.dumps(rows,indent=2))
