#!/usr/bin/env python3
"""Run the unchanged Octane mini inputs serially across four optimized stages."""
import argparse,hashlib,json,os,platform,re,signal,statistics,subprocess,sys,tempfile,threading,time
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
DEFAULT=Path('/Users/rtomasi/cousas/boomkat/.worktrees/octane/bench/mini')
NAMES=['gbemu','zlib','crypto','regexp','earley-boyer','splay','richards','pdfjs','code-load','deltablue','navier-stokes','box2d','mandreel','raytrace','typescript']

def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def execute(binary,source,timeout):
    command=[binary,'--script',str(source)]
    with tempfile.TemporaryFile() as out,tempfile.TemporaryFile() as err:
        started=time.perf_counter_ns()
        p=subprocess.Popen(command,cwd=source.parent,stdout=out,stderr=err,start_new_session=True)
        timed_out=[]
        def kill():
            timed_out.append(True)
            try:os.killpg(p.pid,signal.SIGKILL)
            except ProcessLookupError:pass
        timer=threading.Timer(timeout,kill);timer.start()
        try:_,status,usage=os.wait4(p.pid,0)
        except BaseException:
            try:os.killpg(p.pid,signal.SIGTERM)
            except ProcessLookupError:pass
            try:os.wait4(p.pid,0)
            except ChildProcessError:pass
            raise
        finally:timer.cancel()
        elapsed=(time.perf_counter_ns()-started)/1e9;p.returncode=os.waitstatus_to_exitcode(status)
        out.seek(0);stdout=out.read().decode(errors='replace');err.seek(0);stderr=err.read().decode(errors='replace')
    reported={m[1]:float(m[2]) for m in re.finditer(r'^([^\n:]+):\s*(\d+(?:\.\d+)?) ms\s*$',stdout,re.M)}
    error=re.search(r'\b(?:TypeError|ReferenceError|SyntaxError|AssertionError|Error)\b|\bFAIL(?:ED)?\b',stdout+'\n'+stderr)
    success=p.returncode==0 and not timed_out and bool(reported) and error is None
    return dict(command=command,wall_s=elapsed,cpu_s=usage.ru_utime+usage.ru_stime,peak_rss_bytes=usage.ru_maxrss*(1 if sys.platform=='darwin' else 1024),returncode=p.returncode,timed_out=bool(timed_out),reported_ms=reported,reported_total_ms=sum(reported.values()) if reported else None,success=success,stdout=stdout,stderr=stderr)

def main():
    a=argparse.ArgumentParser(description=__doc__)
    a.add_argument('--source',type=Path,default=DEFAULT);a.add_argument('--rounds',type=int,default=1)
    a.add_argument('--timeout',type=float,default=120);a.add_argument('--pilot',action='store_true');a.add_argument('--only',nargs='*')
    args=a.parse_args();stages=json.loads((HERE/'stages.json').read_text())
    names=[n for n in NAMES if not args.only or n in args.only]
    for stage in stages:
        if sha(stage['binary'])!=stage['binary_sha256']:raise RuntimeError('binary changed: '+stage['name'])
    manifest=[dict(name=n,path=str((args.source/(n+'.js')).resolve()),bytes=(args.source/(n+'.js')).stat().st_size,sha256=sha(args.source/(n+'.js'))) for n in names]
    metadata=dict(created_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),compiler=subprocess.check_output(['c3c','--version'],text=True),platform=platform.platform(),stages=stages,sources=manifest,harness_sources={n:sha(args.source/n) for n in ['run.sh','gen.sh']},source_git_revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=args.source,text=True).strip(),rounds=1 if args.pilot else args.rounds,warmup_rounds=0 if args.pilot else 1,method='Serial children, rotated/reversed stage order; unchanged --script inputs; embedded Date.now sums exclude setup/teardown/initial parse; whole-process wall/CPU and wait4 RSS also recorded.',samples=[])
    dest=HERE/('pilot.json' if args.pilot else 'results.json')
    rounds=[0] if args.pilot else list(range(-1,args.rounds))
    for round_no in rounds:
        ordered=manifest[(max(round_no,0)*3)%len(manifest):]+manifest[:(max(round_no,0)*3)%len(manifest)]
        for source in ordered:
            case_index=NAMES.index(source['name']);offset=(case_index+round_no)%len(stages)
            order=stages[offset:]+stages[:offset]
            if round_no%2:order=list(reversed(order))
            for position,stage in enumerate(order):
                sample=execute(stage['binary'],Path(source['path']),args.timeout)
                sample.update(name=source['name'],stage=stage['name'],round=round_no,warmup=round_no<0,position=position)
                metadata['samples'].append(sample)
                dest.write_text(json.dumps(metadata,indent=2)+'\n')
                rss=sample['peak_rss_bytes']/1048576
                print(f"r{round_no} {source['name']} {stage['name']}: {'PASS' if sample['success'] else 'FAIL'} reported={sample['reported_total_ms']} ms wall={sample['wall_s']:.3f}s RSS={rss:.1f}MiB",flush=True)
                if not sample['success']:print((sample['stderr'] or sample['stdout'])[:500],flush=True)
    for source in manifest:
        if sha(source['path'])!=source['sha256']:raise RuntimeError('source changed during run: '+source['path'])
    print('Recorded:',dest,flush=True)
if __name__=='__main__':main()
