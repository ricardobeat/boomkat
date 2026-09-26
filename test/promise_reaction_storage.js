function eq(a,b){if(a!==b) throw new Error(a+' !== '+b);}
async function check() {
 var events=[], resolve;
 var pending=new Promise(function(r){resolve=r;});
 var ps=[];
 for(var i=0;i<40;i++) ps.push(pending.then(function(v){events.push(v); return v+1;}));
 resolve(2); events.push('sync');
 var values=await Promise.all(ps); eq(events[0],'sync'); eq(events.length,41);
 for(var i=0;i<values.length;i++) eq(values[i],3);
 eq(await Promise.resolve(7).then(),7);
 eq(await Promise.reject(8).then().catch(function(v){return v+1;}),9);
 eq(await Promise.resolve(1).then(function(){throw 4;}).catch(function(v){return v;}),4);
 eq(await Promise.resolve(3).finally(function(){events.push('finally');}),3);
 class Sub extends Promise {}
 var s=Sub.resolve(4).then(function(v){return v+1;}); eq(s instanceof Sub,true); eq(await s,5);
 var inner=Promise.resolve(10);
 eq(await Promise.resolve().then(function(){return inner;}),10);
 eq(await Promise.resolve({then:function(r){r(11);}}),11);
 var count=0;
 async function nested(){for(var i=0;i<50;i++) count+=await Promise.resolve(1);}
 await nested(); eq(count,50);
 print('promise_reaction_storage: passed');
}
check();
