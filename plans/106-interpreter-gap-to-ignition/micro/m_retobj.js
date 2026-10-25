function V(x,y){ this.x=x; this.y=y; }
V.prototype.add = function(o){ return new V(this.x+o.x, this.y+o.y); };
var a = new V(1,2), b = new V(0,0);
bench("ret_obj_method", 3000000, function(n){ var r=b; for (var i=0;i<n;i++) r=r.add(a); return r.x; });
