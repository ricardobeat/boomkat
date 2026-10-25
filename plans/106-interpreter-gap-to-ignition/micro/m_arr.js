var arr=[]; for (var i=0;i<1000;i++) arr.push(i);
bench("array_sum", 20000000, function(n){ var s=0; for (var i=0;i<n;i++) s=(s+arr[i&1023&1023 % 1000 >= 0 ? i%1000 : 0])|0; return s; });
