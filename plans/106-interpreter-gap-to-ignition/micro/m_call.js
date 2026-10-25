function f(a){ return a+1; }
function g(a){ var x=a; return x>0 ? x : 0; }
bench("call_global_fn", 10000000, function(n){ var s=0; for (var i=0;i<n;i++) s=g(i); return s; });
