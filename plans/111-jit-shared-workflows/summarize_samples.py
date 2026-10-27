import sys,json,re,collections
from pathlib import Path
root=Path('/Users/rtomasi/cousas/boomkat/.worktrees/rat');sys.path.insert(0,str(root/'scripts'))
from profile_sljit_sample import self_samples,read_maps
p=Path('/tmp/boomkat-jit-common');rows=[]
for row in json.loads((p/'sample-summary.json').read_text()):
 bench=row['bench'];phase=row['phase'];total=row['total_self_samples'];cats=collections.Counter()
 ranges,_=read_maps((p/f'{bench}-map.txt').read_text())
 for count,symbol in self_samples((p/f'{bench}-{phase}-sample.txt').read_text()):
  a=re.search(r'\[(0x[\da-fA-F]+)\]',symbol);pc=int(a[1],16) if a else -1
  if any(r['start']<=pc<r['end'] for r in ranges):kind='generated'
  elif '<unknown binary>' in symbol:kind='unmapped'
  elif re.search(r'boomkat\.(lexer|parser|compiler|ast)\.',symbol):kind='frontend'
  elif re.search(r'boomkat\.heap\.Heap\.(gc_|mark_|collect|trace_)',symbol):kind='gc'
  elif re.search(r'boomkat\.vm\.(sljit_|loop_|function_)',symbol):kind='jit_runtime'
  elif re.search(r'boomkat\.vm\.(th_|vm_dispatch|run_threaded|dispatch_|execute_)',symbol):kind='interpreter'
  elif re.search(r'\b(lre_|re_run|re_exec)',symbol):kind='regexp'
  else:kind='other_runtime'
  cats[kind]+=count
 row['coarse_cpu_percent']={k:round(v*100/total,2) for k,v in cats.most_common()};rows.append(row)
 print(phase,total,row['coarse_cpu_percent'])
(p/'samples-categorized.json').write_text(json.dumps(rows,indent=2)+'\n')
