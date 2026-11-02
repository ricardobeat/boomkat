import json,re,collections,pathlib
rootdirs=['/tmp/bk-reviewed-native','/tmp/bk-recovery-live-native']
for root,start,stub in zip(rootdirs,[0x964,0x94c],[0x1394,0x120c]):
 item=json.loads(pathlib.Path(root,'manifest.json').read_text())[11]
 base=int(item['native'],16)
 lines=pathlib.Path(item['path']+'.asm').read_text().splitlines()
 code={int(m[1],16):(m[2],m[3]) for ln in lines if (m:=re.match(r'([0-9a-f]+):\s+(\S+)\s*(.*)',ln))}
 path=[];pc=start
 for _ in range(2000):
  op,args=code[pc];path.append((pc,op,args));nextpc=pc+4
  if op=='b' or op.startswith('b.'):
   target=int(args,16)-base
   if op=='b':nextpc=target
   elif target>=stub:pass # successful guards never take cold exit
   elif op in ('b.pl','b.le','b.eq','b.lo','b.ls'):nextpc=target
   elif op in ('b.ne','b.hi','b.hs','b.vs','b.ge','b.mi','b.lt'):pass
   else:raise Exception((hex(pc),op,args))
  elif op in ('cbnz','cbz'):
   target=int(args.rsplit(', ',1)[1],16)-base
   if target>=stub:pass
   elif op=='cbnz':nextpc=target # nonzero positive index
   else:raise Exception((hex(pc),op,args))
  if nextpc==start:break
  if nextpc>=stub:raise Exception(('unexpected cold exit',hex(pc),hex(nextpc)))
  pc=nextpc
 else:raise Exception('no loop')
 counts=collections.Counter();selected=[]
 for pc,op,args in path:
  if op not in ('ldr','str'):continue
  m=re.search(r'\[x19(?:, #0x([0-9a-f]+))?\]',args)
  if m:
   offset=int(m[1],16) if m[1] else 0
   kind='spill' if offset>=0x3a0 else 'state/descriptor'
  elif '[x2]' in args:kind='array'
  else:kind='other'
  counts[(kind,op)]+=1
  if kind=='spill':selected.append(f'{pc:04x}: {op} {args}')
 print(root, 'path_start',hex(start),'backedge',hex(path[-1][0]), 'instructions',len(path))
 print(dict(counts))
 print('Spill offsets/instructions:');print('\n'.join(selected))
 print('sizes',{'prefix':0x75c,'compute_control':(0x1254 if 'reviewed' in root else 0x119c)-0x75c,'call_publish':(0x1364-0x1254 if 'reviewed' in root else 0x11dc-0x119c),'ret_publish':48,'cold_stubs':item['size']-stub,'total':item['size']})
