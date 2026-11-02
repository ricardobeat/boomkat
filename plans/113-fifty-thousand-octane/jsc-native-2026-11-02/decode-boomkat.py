from pathlib import Path
import re,subprocess,json,sys
p=Path(__file__).resolve().parent
source=sys.argv[1] if len(sys.argv)>1 else 'boomkat-release-navier.native.log'
out=p/('boomkat-release-native' if 'release' in source else 'boomkat-native'); out.mkdir(exist_ok=True); rec=[]
for l in (p/source).read_text().splitlines():
 m=re.match(r'REPAIR_NATIVE name=(\w+) begin=(\d+) bytes=(\d+) hex=([0-9a-f]+)',l)
 if not m: continue
 name,begin,size,h=m.groups(); b=bytes.fromhex(h); assert len(b)==int(size); stem=f'{name}-{begin}-{len(rec)}'; (out/(stem+'.bin')).write_bytes(b)
 inp='\n'.join(' '.join('0x'+h[i+j:i+j+2] for j in range(0,8,2)) for i in range(0,len(h),8))+'\n'; r=subprocess.run(['/opt/homebrew/opt/llvm/bin/llvm-mc','--disassemble','--triple=aarch64'],input=inp,text=True,capture_output=True); assert r.returncode==0,r.stderr
 asm=[x for x in r.stdout.splitlines() if x.strip() and x.strip()!='.text']; assert len(asm)*4==len(b),(len(asm),len(b)); (out/(stem+'.asm')).write_text('\n'.join(asm)+'\n'); (out/(stem+'.offsets.asm')).write_text('\n'.join(f'{i*4:6d}: {x}' for i,x in enumerate(asm))+'\n')
 edges=[]
 for i,s in enumerate(asm):
  q=re.search(r'\b(b(?:\.[a-z]+)?|cbn?z|tbn?z)\s+.*?#(-?\d+)',s)
  if q and int(q[2])<0: edges.append([i*4,i*4+int(q[2]),s.strip()])
 rec.append({'name':name,'begin':int(begin),'bytes':len(b),'file':stem,'backward_branches':edges})
print(json.dumps(rec,indent=2)); (out/'manifest.json').write_text(json.dumps(rec,indent=2)+'\n')
