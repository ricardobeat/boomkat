bench("obj_literal", 5000000, function(n){ var s=0; for (var i=0;i<n;i++){ var o={x:i,y:1}; s=(s+o.x)|0; } return s; });
