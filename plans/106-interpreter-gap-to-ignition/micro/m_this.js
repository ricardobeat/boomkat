function C(){ this.a = 1; this.b = 2; this.n = 0; }
C.prototype.run = function(n){ for (var i=0;i<n;i++) this.n = (this.n + this.a + this.b)|0; return this.n; };
var o = new C();
bench("this_rw", 10000000, function(n){ return o.run(n); });
