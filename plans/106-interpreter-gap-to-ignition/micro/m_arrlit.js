bench("arr_literal", 5000000, function(n){ var s=0; for (var i=0;i<n;i++){ var o=[i,1,2]; s=(s+o[0])|0; } return s; });
