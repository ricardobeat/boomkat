// Twenty live values force phi windowing while global helpers inline.
// n is deliberately a mutable loop bound; overflowing helpers trigger recompilation.
function phiAdd(a,b) { return (a+b)|0; }
function phiXor(a,b) { return (a^b)|0; }
function globalPhi(n,seed) {
var a=(seed+1)|0,b=(seed+2)|0,c=(seed+3)|0,d=(seed+4)|0,e=(seed+5)|0,f=(seed+6)|0,g=(seed+7)|0,h=(seed+8)|0,i=(seed+9)|0,j=(seed+10)|0,k=(seed+11)|0,l=(seed+12)|0,m=(seed+13)|0; n=(seed+14)|0; var o=(seed+15)|0,p=(seed+16)|0,q=(seed+17)|0,r=(seed+18)|0,s=(seed+19)|0,t=(seed+20)|0;
for(var x=0;x<n;x++) {
a=phiAdd(a,b);
b=phiXor(b,c);
c=phiAdd(c,d);
d=phiXor(d,e);
e=phiAdd(e,f);
f=phiXor(f,g);
g=phiAdd(g,h);
h=phiXor(h,i);
i=phiAdd(i,j);
j=phiXor(j,k);
k=phiAdd(k,l);
l=phiXor(l,m);
m=phiAdd(m,n);
n=phiXor(n,o);
o=phiAdd(o,p);
p=phiXor(p,q);
q=phiAdd(q,r);
r=phiXor(r,s);
s=phiAdd(s,t);
t=phiXor(t,a);
}
return (a^b^c^d^e^f^g^h^i^j^k^l^m^n^o^p^q^r^s^t)|0;
}
var checksum=0;
for(var warm=0;warm<1500;warm++) checksum=(checksum+globalPhi(8,warm))|0;
if (checksum !== -652726369 || globalPhi(8,123) !== -2078275218) throw new Error("global phi spill corruption");
print("global phi OK");
