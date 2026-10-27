import random,subprocess,pathlib,re,json
r=random.Random(726113);root=pathlib.Path('/tmp/boomkat-ssa-repair');rows=[]
ops=['+','-','*','/','&','|','^','<<','>>','>>>'];rel=['<','<=','>','>=','===','!==']
for batch in range(12):
 lines=['var results=[];']
 for k in range(12):
  c=r.choice(['0.25','-0.5','2','-3','2147483647']);op=r.choice(ops);comp=r.choice(rel);shift=r.choice(['1','2','0'])
  x=r.choice(['i','a[i]','a[i]+0.5','a[i]|0']);y=r.choice(['i+0.5','b[i]','b[i]+0.25','i|0'])
  alt=r.choice(['i','x','x+0.5','x|0'])
  lines.append(f'''function f{k}(a,b,n){{var s=0,p=1,q=2;for(var i=0;i<n;i++){{var x=a[i],y=b[i];if({x} {comp} {y}){{p=(x {op} ({c}));q=y+0.25;}}else{{p=x-({c});q=(y>>>{shift});}}b[i]=p+q;s+=b[i];p={alt};}}return s+p+q;}}
for(var w=0;w<20;w++){{var a=new Float64Array(64),b=new Float64Array(64);for(var i=0;i<64;i++){{a[i]=((i*17+w)%67)-30;b[i]=((i*7+w)%31)-12;}}var z=f{k}(a,w%2?a:b,64);if(w>17)results.push([z,Array.prototype.join.call(a,','),Array.prototype.join.call(b,',')]);}}''')
 lines.append('print(JSON.stringify(results));')
 f=root/f'fuzz-{batch}.js';f.write_text('\n'.join(lines));outs=[]
 for mode,args in [('interp',[]),('jit',['--jit']),('stress',['--jit','--jit-stress'])]:
  p=subprocess.run([str(root/'numeric/boomkat'),*args,'--script',str(f)],capture_output=True,text=True,timeout=90)
  (root/f'fuzz-{batch}-{mode}.txt').write_text(p.stdout+p.stderr)
  assert p.returncode==0,(batch,mode,p.stdout,p.stderr)
  outs.append(p.stdout)
 assert len(set(outs))==1,batch
 print('PASS',batch,flush=True);rows.append(batch)
(root/'fuzz-results.json').write_text(json.dumps(rows))
