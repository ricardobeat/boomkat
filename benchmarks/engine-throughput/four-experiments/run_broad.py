from pathlib import Path
import subprocess,time,json,statistics,argparse,os
p=argparse.ArgumentParser();p.add_argument('--variants',nargs='+',default=['baseline','mul','arrays','slots','clock64','clock128','quickjs']);p.add_argument('--runs',type=int,default=3);p.add_argument('--output',default='broad-results.json');p.add_argument('--files',nargs='+');a=p.parse_args()
base=Path(__import__('os').environ.get('BOOMKAT_EXPERIMENT_DIR', '/tmp/boomkat-four-experiments'));root=Path(__file__).resolve().parents[3];rows=[]
files=['bench_loop','bench_function_call','bench_array','bench_object','bench_recursion','es6/bench_class','es6/bench_destructuring','es6/bench_spread_rest','es6/bench_forof','bench_gc_large_container','bench_gc_native_reentry']
if a.files: files=a.files
for file in files:
 expected=None
 for repeat in range(-1,a.runs):
  names=a.variants[repeat%len(a.variants):]+a.variants[:repeat%len(a.variants)]
  if repeat%2:names=names[::-1]
  for n in names:
   binary=root/'out/qjs' if n=='quickjs' else base/n/'out/boomkat'
   out=base/'broad-child.stdout';err=base/'broad-child.stderr'
   with out.open('w') as stdout,err.open('w') as stderr:
    t=time.perf_counter();child=subprocess.Popen([str(binary),'--script',str(root/'benchmarks'/f'{file}.js')],stdout=stdout,stderr=stderr);pid,status,usage=os.wait4(child.pid,0);child.returncode=os.waitstatus_to_exitcode(status);wall=time.perf_counter()-t
   text=out.read_text()
   if child.returncode or 'FAIL' in text:raise RuntimeError(n+' '+file+' '+err.read_text()+text)
   if expected is None:expected=text
   if expected!=text:raise RuntimeError((n,file,expected,text))
   if repeat>=0:
    rows.append(dict(variant=n,file=file,repeat=repeat,wall=wall,rss=usage.ru_maxrss,stdout=text));(base/a.output).write_text(json.dumps(rows,indent=2))
 med={n:statistics.median(r['wall'] for r in rows if r['file']==file and r['variant']==n) for n in a.variants}
 print(file,{n:round(v,4) for n,v in med.items()},flush=True)
