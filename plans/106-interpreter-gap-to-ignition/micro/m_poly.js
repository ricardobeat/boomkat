function A(){this.x=1;} function B(){this.y=0;this.x=2;} function Cc(){this.z=0;this.w=0;this.x=3;}
var os=[new A(),new B(),new Cc(),new A()];
bench("poly3_read", 10000000, function(n){ var s=0; for (var i=0;i<n;i++) s=(s+os[i&3].x)|0; return s; });
