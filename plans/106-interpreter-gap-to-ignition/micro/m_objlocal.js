function N(){ this.next = null; this.v = 1; } N.prototype.f = function(){ var t = this.next; return t.v; };
var a = new N(), b = new N(); a.next = b;
bench("obj_in_local_ret_prim", 10000000, function(n){ var s=0; for (var i=0;i<n;i++) s=(s+a.f())|0; return s; });
