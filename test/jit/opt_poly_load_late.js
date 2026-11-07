// Shapes learned after compilation must use the retained set without rebuilding.
function make(k) {
    var o=Object.create({x:k+0.5});
    o['shape'+k]=k;
    return o;
}
var a=[make(0),make(1)], c=make(2), d=make(3);
function read(n) {
    var s=0.5;
    for(var i=0;i<n;i++) s+=a[i%a.length].x;
    return s;
}
for(var r=0;r<4;r++) print(read(3000));
a.push(c); for(var r=0;r<4;r++) print(read(3000));
a.push(d); for(var r=0;r<4;r++) print(read(3000));
