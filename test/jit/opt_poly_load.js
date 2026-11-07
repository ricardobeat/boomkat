// Inherited loads retain receiver-shape/first-prototype/owner/slot cases.
// Compare all execution tiers, including forced exits after mutations.
var out = [];
function make(k) {
    var p = k & 1 ? { pad: 99, x: k + 0.5 } : { x: k + 0.5 };
    var o = Object.create(p);
    o['tag' + k] = k;
    return o;
}
function sum(a, n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s += a[i % a.length].x;
    return s;
}
// Separate functions keep independent feedback for each cardinality.
function two(a) { var s = 0.5; for (var i=0;i<1800;i++) s += a[i%2].x; return s; }
function three(a) { var s = 0.5; for (var i=0;i<1800;i++) s += a[i%3].x; return s; }
function four(a) { var s = 0.5; for (var i=0;i<1800;i++) s += a[i%4].x; return s; }
function five(a) { var s = 0.5; for (var i=0;i<1800;i++) s += a[i%5].x; return s; }
var a = [make(0), make(1), make(2), make(3), make(4)];
for (var r=0;r<4;r++) out.push(two(a), three(a), four(a), five(a));
for (var r=0;r<4;r++) out.push(sum(a.slice(0,2),1800));
out.push(sum(a,1800)); // new receiver after warmup
out.push(sum(a.concat([make(5)]),1800)); // exceed primary plus four retained cases
Object.getPrototypeOf(a[0]).x = 101.5;
out.push(two(a), four(a)); // epoch invalidation, changed owner value
Object.defineProperty(Object.getPrototypeOf(a[1]), 'x', {get:function(){return 23.5;}, configurable:true});
out.push(two(a), four(a)); // accessor must run
Object.defineProperty(Object.getPrototypeOf(a[1]), 'x', {value:7.5, writable:true, configurable:true});
a[2].x = 9.5; out.push(three(a)); // own shadow and shape transition
delete a[2].x; out.push(three(a));
Object.setPrototypeOf(a[3], {x:51.5}); out.push(four(a));
// An intermediate prototype shadows and then reveals a deeper owner.
var root={x:12.5}, middle=Object.create(root), child=Object.create(middle);
child.tag=1;
for(var r=0;r<4;r++) out.push(sum([child,a[0]],1800));
middle.x=71.5; out.push(sum([child,a[0]],1800));
delete middle.x; out.push(sum([child,a[0]],1800));
// Deprecate receiver shapes and exercise retained prototype roots during collections.
for(var r=0;r<4;r++) {
    var old=a[r]; delete old['tag'+r]; old['replacement'+r]=r;
    var junk=[];
    for(var j=0;j<16000;j++) junk.push({x:j, y:j+0.5});
    out.push(four(a));
}
// Parameter slots put the receiver above 255 without a large/pressure-heavy body.
function wide(unused0,unused1,unused2,unused3,unused4,unused5,unused6,unused7,unused8,unused9,unused10,unused11,unused12,unused13,unused14,unused15,unused16,unused17,unused18,unused19,unused20,unused21,unused22,unused23,unused24,unused25,unused26,unused27,unused28,unused29,unused30,unused31,unused32,unused33,unused34,unused35,unused36,unused37,unused38,unused39,unused40,unused41,unused42,unused43,unused44,unused45,unused46,unused47,unused48,unused49,unused50,unused51,unused52,unused53,unused54,unused55,unused56,unused57,unused58,unused59,unused60,unused61,unused62,unused63,unused64,unused65,unused66,unused67,unused68,unused69,unused70,unused71,unused72,unused73,unused74,unused75,unused76,unused77,unused78,unused79,unused80,unused81,unused82,unused83,unused84,unused85,unused86,unused87,unused88,unused89,unused90,unused91,unused92,unused93,unused94,unused95,unused96,unused97,unused98,unused99,unused100,unused101,unused102,unused103,unused104,unused105,unused106,unused107,unused108,unused109,unused110,unused111,unused112,unused113,unused114,unused115,unused116,unused117,unused118,unused119,unused120,unused121,unused122,unused123,unused124,unused125,unused126,unused127,unused128,unused129,unused130,unused131,unused132,unused133,unused134,unused135,unused136,unused137,unused138,unused139,unused140,unused141,unused142,unused143,unused144,unused145,unused146,unused147,unused148,unused149,unused150,unused151,unused152,unused153,unused154,unused155,unused156,unused157,unused158,unused159,unused160,unused161,unused162,unused163,unused164,unused165,unused166,unused167,unused168,unused169,unused170,unused171,unused172,unused173,unused174,unused175,unused176,unused177,unused178,unused179,unused180,unused181,unused182,unused183,unused184,unused185,unused186,unused187,unused188,unused189,unused190,unused191,unused192,unused193,unused194,unused195,unused196,unused197,unused198,unused199,unused200,unused201,unused202,unused203,unused204,unused205,unused206,unused207,unused208,unused209,unused210,unused211,unused212,unused213,unused214,unused215,unused216,unused217,unused218,unused219,unused220,unused221,unused222,unused223,unused224,unused225,unused226,unused227,unused228,unused229,unused230,unused231,unused232,unused233,unused234,unused235,unused236,unused237,unused238,unused239,unused240,unused241,unused242,unused243,unused244,unused245,unused246,unused247,unused248,unused249,unused250,unused251,unused252,unused253,unused254,unused255,unused256,unused257,unused258,unused259,a) {
    var s=0.5;
    for(var i=0;i<1800;i++) s+=a[i%a.length].x;
    return s;
}
var args=[];
for(var k=0;k<260;k++) args.push(null);
args.push(a.slice(0,2));
for(var r=0;r<4;r++) out.push(wide.apply(null,args));
args[260]=a; out.push(wide.apply(null,args));
print(out.join(','));
