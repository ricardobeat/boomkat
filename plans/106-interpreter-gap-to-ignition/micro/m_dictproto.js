function Big(){ this.v = 1; }
for (var k = 0; k < 80; k++) Big.prototype["m" + k] = function(){ return this.v; };
function Small(){ this.v = 1; }
for (var k = 0; k < 20; k++) Small.prototype["m" + k] = function(){ return this.v; };
var b = new Big(), s = new Small();
bench("proto_20_methods", 5000000, function(n){ var r=0; for (var i=0;i<n;i++) r=(r+s.m7())|0; return r; });
bench("proto_80_methods_dict", 5000000, function(n){ var r=0; for (var i=0;i<n;i++) r=(r+b.m7())|0; return r; });
