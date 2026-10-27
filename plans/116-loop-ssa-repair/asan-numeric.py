import subprocess,pathlib,os
root=pathlib.Path('/tmp/boomkat-ssa-repair')
files=sorted(pathlib.Path('test').glob('sljit_ssa*.js'))+[pathlib.Path('test/sljit_loop.js'),pathlib.Path('test/jit_loop_arms.js'),root/'cfg-corpus.js']+sorted(pathlib.Path('bench/mini').glob('*.js'))
for f in files:
 p=subprocess.run([str(root/'numeric-asan/boomkat'),'--jit','--script',str(f)],capture_output=True,text=True,timeout=240,env={**os.environ,'ASAN_OPTIONS':'detect_leaks=0'})
 print(f,p.returncode,p.stdout,p.stderr,flush=True)
 assert p.returncode==0,f
print('TOTAL PASS',len(files),flush=True)
