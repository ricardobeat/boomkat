function eq(a,b) { if(a!==b) throw new Error('checksum '+a+' '+b); }
var N=30000;
async function run() {
 var p=Promise.resolve(0);
 for(var i=0;i<N;i++) p=p.then(function(v){return v+1;});
 eq(await p,N);
 var sum=0;
 for(var i=0;i<N;i++) sum+=await Promise.resolve(1);
 eq(sum,N);
 var resolve; var pending=new Promise(function(r){resolve=r;}); var all=[];
 for(var i=0;i<N;i++) all.push(pending.then(function(x){return x+2;}));
 resolve(3);
 var values=await Promise.all(all); sum=0;
 for(var i=0;i<values.length;i++) sum+=values[i];
 eq(sum,5*N); print('promise reactions: passed');
}
run().catch(function(error) { print("FAIL " + error); });
