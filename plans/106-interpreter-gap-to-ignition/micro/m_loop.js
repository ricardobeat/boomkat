bench("empty_loop", 30000000, function(n){ var s=0; for (var i=0;i<n;i++) s=(s+i)|0; return s; });
