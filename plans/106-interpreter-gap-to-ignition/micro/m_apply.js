var Class = { create: function() { return function() { this.initialize.apply(this, arguments); }; } };
var V = Class.create(); V.prototype = { initialize: function(x, y) { this.x = x; this.y = y; } };
function W(x, y) { this.x = x; this.y = y; }
bench("new_direct_ctor", 3000000, function(n){ var s=0; for (var i=0;i<n;i++){ var v=new W(i,1); s=(s+v.x)|0; } return s; });
bench("new_via_apply_arguments", 3000000, function(n){ var s=0; for (var i=0;i<n;i++){ var v=new V(i,1); s=(s+v.x)|0; } return s; });
