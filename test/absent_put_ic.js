function P(x){this.x=x;this.y=2;}
var a=[];for(var i=0;i<50;i++)a.push(new P(i));
// proto gains a setter after the IC is warm: later stores must call it
var hit=0;Object.defineProperty(P.prototype,"y",{set:function(v){hit++;},configurable:true});
var b=new P(1);
if(hit!==1||b.hasOwnProperty("y"))throw new Error("setter missed "+hit);
delete P.prototype.y;
// frozen / non-extensible receivers
function Q(o){o.z=1;}
for(var i=0;i<20;i++)Q({});
var f=Object.preventExtensions({});Q(f);if("z" in f)throw new Error("ext");
// string values (refcounted) and objects
function R(s,o){this.s=s;this.o=o;this.n=1;}
var r;for(var i=0;i<100;i++)r=new R("a"+i,{k:i});
if(r.s!=="a99"||r.o.k!==99)throw new Error("ref");
// growth past inline capacity and the hash threshold
function W(){this.a=1;this.b=2;this.c=3;this.d=4;this.e=5;this.f=6;this.g=7;this.h=8;this.i=9;this.j=10;}
var w;for(var i=0;i<100;i++)w=new W();
if(Object.keys(w).join()!=="a,b,c,d,e,f,g,h,i,j"||w.j!==10)throw new Error("grow");
// delete then re-add
function D(){this.p=1;this.q=2;}
for(var i=0;i<10;i++){var d=new D();delete d.p;d.p=3;if(Object.keys(d).join()!=="q,p")throw new Error("del");}
console.log("ok");
