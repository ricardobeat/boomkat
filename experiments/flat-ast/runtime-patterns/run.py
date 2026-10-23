#!/usr/bin/env python3
"""One serial, alternating-order mini comparison; no warmup or repeated rounds."""
import hashlib,importlib.util,json,platform,subprocess
from pathlib import Path
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('mini_runner',HERE.parent/'mini'/'run.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
source=Path('/Users/rtomasi/cousas/boomkat/.worktrees/octane/bench/mini')
data={'platform':platform.platform(),'revision':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'rounds':1,'warmups':0,'binaries':{s:m.sha(HERE/'bin'/s) for s in ['before','after']},'samples':[]}
for i,n in enumerate(m.NAMES):
 for s in (['before','after'] if i%2==0 else ['after','before']):
  r=m.execute(str(HERE/'bin'/s),source/(n+'.js'),120)
  r.update(name=n,stage=s,source_sha256=m.sha(source/(n+'.js')))
  data['samples'].append(r);(HERE/'results.json').write_text(json.dumps(data,indent=2)+'\n')
  print(n,s,'PASS' if r['success'] else 'FAIL',r['reported_total_ms'],'ms',round(r['peak_rss_bytes']/1048576,2),'MiB',flush=True)
  if not r['success']: print(r['stdout'],r['stderr'],flush=True)
