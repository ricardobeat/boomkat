function N(){ this.next = null; this.v = 1; } N.prototype.getNext = function(){ return this.next; };
var a = new N(), b = new N(); a.next = b; b.next = a;
bench("ret_obj_field", 10000000, function(n){ var r=a; for (var i=0;i<n;i++) r=r.getNext(); return r.v; });
