// One read site meets objects that inherit a property and objects that hold it themselves: the
// optimized read learns both kinds and must return each object's own value or its prototype's.

function Info() {}
Info.prototype.hit = false;
Info.prototype.scale = 3;

function make(i) {
    var o = new Info();
    if (i % 3 === 0) o.hit = true;
    if (i % 5 === 0) o.scale = i;
    return o;
}

function readHit(o) { return o.hit; }
function readScale(o) { return o.scale; }

var objs = [];
for (var i = 0; i < 64; i++) objs.push(make(i));

function countHits(list, rounds) {
    var hits = 0;
    for (var round = 0; round < rounds; round++) {
        for (var i = 0; i < list.length; i++) if (readHit(list[i])) hits++;
    }
    return hits;
}

function sumScale(list, rounds) {
    var sum = 0;
    for (var round = 0; round < rounds; round++) {
        for (var i = 0; i < list.length; i++) sum += readScale(list[i]);
    }
    return sum;
}

// Each kind of receiver alone first, so that the entry settles on it before the other turns up.
var own = objs.filter(function (o, i) { return i % 15 === 0; });
var inherited = objs.filter(function (o, i) { return i % 3 !== 0 && i % 5 !== 0; });
if (countHits(inherited, 3000) !== 0) throw new Error("inherited hits");
if (countHits(own, 3000) !== own.length * 3000) throw new Error("own hits");
if (sumScale(own, 3000) !== 3000 * own.reduce(function (a, o) { return a + o.scale; }, 0)) throw new Error("own scale");

var hits = countHits(objs, 3000), sum = sumScale(objs, 3000);
var expectHits = 0, expectSum = 0;
for (var i = 0; i < 64; i++) {
    if (i % 3 === 0) expectHits++;
    expectSum += i % 5 === 0 ? i : 3;
}
if (hits !== expectHits * 3000) throw new Error("hits " + hits);
if (sum !== expectSum * 3000) throw new Error("sum " + sum);

// The prototype's value changes: inherited reads see it, own reads keep theirs.
Info.prototype.scale = 7;
sum = sumScale(objs, 1000);
expectSum = 0;
for (var i = 0; i < 64; i++) expectSum += i % 5 === 0 ? i : 7;
if (sum !== expectSum * 1000) throw new Error("sum after prototype change " + sum);

// An own property removed falls back to the prototype.
delete objs[0].hit;
if (countHits([objs[0]], 1000) !== 0) throw new Error("deleted own property still read");

// A null-prototype object with the property of its own.
var bare = Object.create(null);
bare.hit = true;
if (countHits([bare, objs[3], objs[1]], 1000) !== 2000) throw new Error("null-prototype own read");

console.log("ok");
