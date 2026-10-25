function lst(){ var r=0; for (var i=arguments.length-1;i>=0;i--) r=(r+arguments[i])|0; return r; }
function at(d,n){ if (d>0) return at(d-1,n); var s=0; for (var i=0;i<n;i++) s=(s+lst(1,2,3))|0; return s; }
bench("args_depth0", 1000000, function(n){ return at(0,n); });
bench("args_depth50", 1000000, function(n){ return at(50,n); });
bench("args_depth200", 1000000, function(n){ return at(200,n); });
