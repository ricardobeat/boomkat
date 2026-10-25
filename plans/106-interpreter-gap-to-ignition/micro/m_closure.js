function mk(){ var k=3; return function(a){ return a+k; }; }
var h = mk();
bench("closure_call", 10000000, function(n){ var s=0; for (var i=0;i<n;i++) s=h(i); return s; });
