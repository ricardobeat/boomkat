#!/usr/bin/env python3
"""Compare optimized bb4738ea and the extended prototype. No conformance runner.

Each workload gets one warmup pair and seven measured A/B pairs in alternating
order. wait4 supplies per-child peak RSS and CPU time. Runtime uses release;
compile-only timings use matching O2 debug targets with their internal timer.
"""
import argparse, collections, gzip, hashlib, json, os, platform, random, re
import statistics, subprocess, sys, tempfile, time
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]

def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def run(command):
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        start=time.perf_counter_ns()
        p=subprocess.Popen(command,stdout=out,stderr=err,cwd=ROOT)
        _,status,usage=os.wait4(p.pid,0)
        wall=(time.perf_counter_ns()-start)/1e9
        p.returncode=os.waitstatus_to_exitcode(status)
        out.seek(0); stdout=out.read().decode(); err.seek(0); stderr=err.read().decode()
        if p.returncode or 'FAIL' in stdout: raise RuntimeError((command,p.returncode,stdout[:1000],stderr[:1000]))
        match=re.search(r'compile:\s+(\d+) us',stdout)
        return dict(wall_s=wall,cpu_s=usage.ru_utime+usage.ru_stime,
                    peak_rss_bytes=usage.ru_maxrss*(1 if sys.platform=='darwin' else 1024),
                    compile_s=int(match[1])/1e6 if match else None,
                    stdout=stdout,stderr=stderr,command=command)

def normalized(s):
    return re.sub(r'total=\d+ms worst_frame=\d+ms','timing',s)

def stats(xs):
    middle=statistics.median(xs)
    return dict(median=middle,min=min(xs),max=max(xs),mad=statistics.median(abs(x-middle) for x in xs))

def summarize(samples,kind):
    groups={side:[x for x in samples if x['side']==side and not x['warmup']] for side in ['baseline','prototype']}
    result={side:{key:stats([x[key] for x in group]) for key in ['wall_s','cpu_s','peak_rss_bytes']+(['compile_s'] if kind=='compile' else [])} for side,group in groups.items()}
    key='compile_s' if kind=='compile' else 'wall_s'
    a=[x[key] for x in groups['baseline']]; b=[x[key] for x in groups['prototype']]
    ratios=[y/x for x,y in zip(a,b)]
    rng=random.Random(1729)
    boot=[]
    for _ in range(5000):
        indexes=[rng.randrange(len(a)) for _ in a]
        boot.append(statistics.median(b[i] for i in indexes)/statistics.median(a[i] for i in indexes))
    boot.sort()
    result.update(metric=key,ratio=statistics.median(b)/statistics.median(a),paired_ratio_median=statistics.median(ratios),paired_ratio_min=min(ratios),paired_ratio_max=max(ratios),paired_bootstrap_95=[boot[125],boot[4874]])
    return result

def bytecode(binary,path,name,side):
    r=subprocess.run([binary,'--format','json',str(path)],cwd=ROOT,capture_output=True,check=True)
    data=json.loads(r.stdout)
    target=HERE/'bytecode'/(name+'.'+side+'.json.gz')
    target.write_bytes(gzip.compress(r.stdout,mtime=0))
    functions=[]
    def visit(nodes):
        for f in nodes:
            ops=collections.Counter(i['text'].split()[0] for i in f['instructions'])
            functions.append(dict(name=f.get('name'),instructions=len(f['instructions']),ops=dict(ops)))
            visit(f.get('inner_functions',[]))
    visit(data)
    ops=collections.Counter()
    for f in functions: ops.update(f['ops'])
    return dict(instructions=sum(f['instructions'] for f in functions),instruction_bytes=sum(f['instructions'] for f in functions)*4,function_count=len(functions),ops=dict(ops),kernel=[f for f in functions if f['name']=='kernel'],artifact=str(target.relative_to(ROOT)),sha256=hashlib.sha256(r.stdout).hexdigest())

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-root',type=Path,default=Path('/private/tmp/boomkat-flat-ast-baseline'))
    parser.add_argument('--pairs',type=int,default=7)
    parser.add_argument('--only',nargs='*')
    parser.add_argument('--skip-bytecode',action='store_true')
    args=parser.parse_args()
    binaries={side:{kind:str((root/'out'/name).resolve()) for kind,name in [('runtime','boomkat'),('compile','boomkat_debug')]} for side,root in [('baseline',args.baseline_root),('prototype',ROOT)]}
    manifest=json.loads((HERE/'manifest.json').read_text())
    if args.only: manifest=[w for w in manifest if w['name'] in args.only]
    baseline_revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=args.baseline_root,text=True).strip()
    prototype_revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    common_revision=subprocess.check_output(['git','merge-base',baseline_revision,'HEAD'],cwd=ROOT,text=True).strip()
    metadata=dict(created_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),baseline_revision=baseline_revision,prototype_base_revision=common_revision,prototype_source_revision=prototype_revision,compiler=subprocess.check_output(['c3c','--version'],text=True),platform=platform.platform(),machine=platform.machine(),cpu_threads=os.cpu_count(),pairs=args.pairs,warmup_pairs=1,binaries={side:{kind:dict(path=path,bytes=Path(path).stat().st_size,sha256=digest(path)) for kind,path in values.items()} for side,values in binaries.items()},method='Optimizations enabled on both sides. Alternating AB/BA pairs; release whole-process runtime; O2 debug internal compile-only timer. RSS is per-child wait4 ru_maxrss in bytes. No CPU affinity or system-wide exclusivity.',results=[])
    patch=subprocess.check_output(['git','diff','--binary',metadata['baseline_revision'],'--','src','cli','project.json','Makefile','scripts/build.py'],cwd=ROOT)
    (HERE/'prototype.patch').write_bytes(patch)
    metadata['source_patch_sha256']=hashlib.sha256(patch).hexdigest()
    dest=HERE/('pilot.json' if args.only else 'results.json')
    for workload in manifest:
        path=(ROOT/workload['path']).resolve()
        samples=[]
        for pair in range(-1,args.pairs):
            for position,side in enumerate(['baseline','prototype'] if pair%2==0 else ['prototype','baseline']):
                options=['--script'] if workload['kind']=='runtime' else ['-d','--check']
                sample=run([binaries[side][workload['kind']],*options,str(path)])
                sample.update(side=side,pair=pair,position=position,warmup=pair<0)
                samples.append(sample)
        if workload['kind']=='runtime':
            outputs={normalized(x['stdout']) for x in samples}
            if len(outputs)!=1: raise RuntimeError(('different observable outputs',workload['name'],outputs))
        row=dict(**workload,source_bytes=path.stat().st_size,source_sha256=digest(path),summary=summarize(samples,workload['kind']))
        raw_name=('pilot.' if args.only else '')+workload['name']+'.json'
        raw_path=HERE/'raw'/raw_name
        raw_path.write_text(json.dumps(samples,indent=2)+'\n')
        row['raw_artifact']=str(raw_path.relative_to(ROOT))
        if not args.skip_bytecode:
            row['bytecode']={side:bytecode(binaries[side]['compile'],path,workload['name'],side) for side in binaries}
        metadata['results'].append(row)
        dest.write_text(json.dumps(metadata,indent=2)+'\n')
        s=row['summary']; key=s['metric']
        print(f"{workload['name']}: {s['baseline'][key]['median']*1000:.3f} -> {s['prototype'][key]['median']*1000:.3f} ms ({100*(s['ratio']-1):+.1f}%), RSS {s['baseline']['peak_rss_bytes']['median']/1048576:.2f} -> {s['prototype']['peak_rss_bytes']['median']/1048576:.2f} MiB",flush=True)
    print('Results:',dest,flush=True)
if __name__=='__main__': main()
