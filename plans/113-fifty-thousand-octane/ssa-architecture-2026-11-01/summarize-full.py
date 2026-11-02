from pathlib import Path
import re,json,math,statistics,sys
p=Path(sys.argv[1]);d=json.loads((p/'results.json').read_text());rows=[]
for i in sorted({r['pair'] for r in d['runs']}):
 a=dict((k,int(v))for k,v in re.findall(r'^([^:\n]+): ([0-9]+)$',(p/f'pair{i}-baseline.log').read_text(),re.M));b=dict((k,int(v))for k,v in re.findall(r'^([^:\n]+): ([0-9]+)$',(p/f'pair{i}-candidate.log').read_text(),re.M));rows.append((a,b))
out={'benchmark_change_percent':{k:100*(math.exp(sum(math.log(b[k]/a[k]) for a,b in rows)/len(rows))-1)for k in rows[0][0]}}
for side in ['baseline','candidate']:
 runs=[r for r in d['runs']if r['side']==side];out[side]={'scores':[r['score']for r in runs],'score_median':statistics.median(r['score']for r in runs),'cpu_median':statistics.median(r['cpu_seconds']for r in runs),'wall_median':statistics.median(r['seconds']for r in runs),'rss_median_bytes':statistics.median(r['maxrss_bytes']for r in runs)}
(p/'summary.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
