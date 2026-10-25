function T(){ this.a=1; } 
T.prototype.f1=function(x){return this.f2(x)+1;}; T.prototype.f2=function(x){return this.f3(x)+1;};
T.prototype.f3=function(x){return this.f4(x)+1;}; T.prototype.f4=function(x){return x+this.a;};
var t=new T();
bench("call_chain4", 5000000, function(n){ var s=0; for (var i=0;i<n;i++) s=(s+t.f1(i))|0; return s; });
