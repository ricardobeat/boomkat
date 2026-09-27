function eq(a,b){if(a!==b) throw new Error(a+' !== '+b);}
function make(x,y){return {alpha:x,beta:y,gamma:undefined,delta:null};}
var a=make(1,2),b=make(3,4);
eq(a.alpha,1);eq(b.beta,4);eq(Object.keys(a).join(','),'alpha,beta,gamma,delta');
a.alpha=8;eq(b.alpha,3);delete a.beta;eq(b.beta,4);
Object.defineProperty(a,'alpha',{writable:false});eq(Object.getOwnPropertyDescriptor(b,'alpha').writable,true);
var c=make({v:9},'s');eq(c.alpha.v,9);eq(c.beta,'s');
function one(x){return {key:x};}
var x=one(2);delete x.key;eq(one(3).key,3);
var calls=0;Object.defineProperty(Object.prototype,'alpha',{set:function(){calls++;},configurable:true});
eq(make(5,6).alpha,5);eq(calls,0);delete Object.prototype.alpha;
var duplicate={a:1,a:2};eq(duplicate.a,2);
var numeric={2:'b',1:'a',x:'c'};eq(Object.keys(numeric).join(','),'1,2,x');
var proto={z:1};eq(({__proto__:proto,x:2}).z,1);
var computed='q';eq(({[computed]:3}).q,3);
var effects=[];var d={a:(effects.push(1),2),b:(effects.push(3),4)};eq(effects.join(','),'1,3');
function many(x){return {a:x,b:x,c:x,d:x,e:x,f:x,g:x,h:x};}
for(var i=0;i<10000;i++){var o=many(i);eq(o.h,i);}
function two(v){return {a:v,b:v};}
function sixteen(v){return {a:v,b:v,c:v,d:v,e:v,f:v,g:v,h:v,i:v,j:v,k:v,l:v,m:v,n:v,o:v,p:v};}
function seventeen(v){return {a:v,b:v,c:v,d:v,e:v,f:v,g:v,h:v,i:v,j:v,k:v,l:v,m:v,n:v,o:v,p:v,q:v};}
eq(two(2).b,2);
var full=sixteen({value:16});eq(Object.keys(full).length,16);eq(full.p.value,16);
delete full.p;eq(sixteen(17).p,17);
eq(Object.keys(seventeen(18)).length,17);eq(seventeen(18).q,18);
print('literal_shape: passed');
