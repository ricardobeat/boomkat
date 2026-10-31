import random
rng=random.Random(2749)
p='/tmp/bk-join-generated.js'
ops=['+','-','*']
with open(p,'w') as f:
 for i in range(30):
  k=rng.randrange(1,10); l=rng.randrange(1,10); m=rng.randrange(1,7); op=rng.choice(ops)
  f.write(f'function f{i}(x,y,a,b){{var p=x+{k},q=y-{l},t;if(a){{p=p{op}{m};}}else{{t=p;p=q;q=t;}}if(b){{t=q;q=p;p=t;}}else{{q=q+{m};}}return p*7+q;}}\n')
  f.write(f'function d{i}(x,y,a,b){{return f{i}(x,y,a,b)+1;}}\n')
 f.write('var total=0;for(var j=0;j<1000;j++){var x=(j%19)-9.5,y=(j%23)-11,a=!!(j&1),b=!!(j&2);\n')
 for i in range(30): f.write(f'total+=d{i}(x,y,a,b);\n')
 f.write('}console.log("generated join total: "+total);\n')
