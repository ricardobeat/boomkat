function N(){ this.next = null; this.v = 1; } N.prototype.getV = function(){ return this.v; };
var a = new N();
bench("ret_prim_field", 10000000, function(n){ var s=0; for (var i=0;i<n;i++) s=(s+a.getV())|0; return s; });
