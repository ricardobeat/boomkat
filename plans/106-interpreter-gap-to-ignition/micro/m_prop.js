function C(){ this.a = 1; this.b = 2; this.c = 3; }
var o = new C();
bench("prop_read3", 10000000, function(n){ var s=0; for (var i=0;i<n;i++) s=(s+o.a+o.b+o.c)|0; return s; });
