import subprocess, time, json, re, statistics, math, hashlib, platform
from pathlib import Path
ROOT=Path(__file__).resolve().parent
META=json.loads((ROOT/'metadata.json').read_text())
CASES=sorted(p.stem for p in (ROOT/'rat'/'bench'/'mini').glob('*.js') if p.stem!='strings-intl')
CONFIGS={'main':[str(ROOT/'main-bin'/'boomkat')], 'rat':[str(ROOT/'rat-bin'/'boomkat'),'--jit']}
META.update({'compiler':subprocess.run(['c3c','--version'],capture_output=True,text=True).stdout,'platform':platform.platform(),'machine':platform.machine(),'configs':CONFIGS,'pairs':5,'warmups':1,'input_source':'rat snapshot; identical files for both binaries','excluded':['strings-intl: not an Octane mini'],'inputs':{n:hashlib.sha256((ROOT/'rat'/'bench'/'mini'/f'{n}.js').read_bytes()).hexdigest() for n in CASES},'binary_sha256':{b:hashlib.sha256(Path(c[0]).read_bytes()).hexdigest() for b,c in CONFIGS.items()}})
(ROOT/'metadata.json').write_text(json.dumps(META,indent=2))
rows=[]
def run(case,branch,phase,pair):
 cmd=['/usr/bin/time','-l',*CONFIGS[branch],'--script',str(ROOT/'rat'/'bench'/'mini'/f'{case}.js')]
 start=time.perf_counter()
 try:
  p=subprocess.run(cmd,capture_output=True,text=True,timeout=120,cwd=ROOT/'rat')
  record={'case':case,'branch':branch,'phase':phase,'pair':pair,'status':p.returncode,'wall_seconds':time.perf_counter()-start,'stdout':p.stdout,'stderr':p.stderr}
  parts=[];bad=[]
  for line in p.stdout.splitlines():
   if not line.strip(): continue
   m=re.fullmatch(r'(.+):\s+(\d+(?:\.\d+)?) ms',line)
   if m: parts.append({'name':m[1],'ms':float(m[2])})
   else: bad.append(line)
  record.update(parts=parts,total_ms=sum(x['ms'] for x in parts),unexpected_output=bad)
  rss=re.search(r'(\d+)\s+maximum resident set size',p.stderr)
  record['max_rss_bytes']=int(rss[1]) if rss else None
  record['valid']=p.returncode==0 and bool(parts) and not bad
 except subprocess.TimeoutExpired as e:
  record={'case':case,'branch':branch,'phase':phase,'pair':pair,'status':'timeout','valid':False,'stdout':str(e.stdout),'stderr':str(e.stderr)}
 rows.append(record)
 (ROOT/'raw.json').write_text(json.dumps(rows,indent=2))
 if not record['valid']: print('FAIL',case,branch,phase,pair,record,flush=True)
 return record
print(f'Warmup: {len(CASES)} Octane mini files, each binary sequentially',flush=True)
for i,case in enumerate(CASES):
 for branch in (['main','rat'] if i%2==0 else ['rat','main']): run(case,branch,'warmup',-1)
 print('warm',case,flush=True)
for pair in range(5):
 print('PAIR',pair+1,flush=True)
 for i,case in enumerate(CASES):
  order=['main','rat'] if (pair+i)%2==0 else ['rat','main']
  records=[run(case,b,'measured',pair) for b in order]
  print('pair',pair+1,case,' '.join(f"{x['branch']}={x.get('total_ms','ERR')}ms" for x in records),flush=True)
summary=[]
for case in CASES:
 values={b:[r for r in rows if r['case']==case and r['branch']==b and r['phase']=='measured'] for b in CONFIGS}
 valid=all(len(v)==5 and all(r['valid'] for r in v) for v in values.values())
 row={'case':case,'valid':valid}
 if valid:
  for b,v in values.items():
   times=[r['total_ms'] for r in v]
   row[b]={'median_ms':statistics.median(times),'min_ms':min(times),'max_ms':max(times),'samples_ms':times,'median_wall_ms':statistics.median(r['wall_seconds']*1000 for r in v),'median_rss_bytes':statistics.median(r['max_rss_bytes'] for r in v if r['max_rss_bytes'] is not None)}
  row['ratio']=row['main']['median_ms']/row['rat']['median_ms']
  row['rat_time_change_pct']=(row['rat']['median_ms']/row['main']['median_ms']-1)*100
 summary.append(row)
valid=[x for x in summary if x['valid']]
aggregate={'rows':summary,'geomean_speedup':math.exp(sum(math.log(r['ratio']) for r in valid)/len(valid)) if valid else None,'all_valid':len(valid)==len(CASES) and all(r['valid'] for r in rows)}
(ROOT/'summary.json').write_text(json.dumps(aggregate,indent=2))
print(json.dumps(aggregate,indent=2),flush=True)
