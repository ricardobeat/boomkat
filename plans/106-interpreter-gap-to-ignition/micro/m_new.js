function V(x,y){ this.x=x; this.y=y; }
bench("new_obj", 5000000, function(n){ var s=0; for (var i=0;i<n;i++){ var v=new V(i,1); s=(s+v.x)|0; } return s; });
