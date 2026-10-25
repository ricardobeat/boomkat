function C(){ this.v = 1; } C.prototype.m = function(a){ return this.v > a ? a : this.v; };
var o = new C();
bench("method_call", 10000000, function(n){ var s=0; for (var i=0;i<n;i++) s=o.m(i); return s; });
