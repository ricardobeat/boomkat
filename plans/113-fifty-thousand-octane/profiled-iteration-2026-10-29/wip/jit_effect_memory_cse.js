function check(ok, message) { if (!ok) throw new Error(message); }
function memorySink(value) { return value; }

// Read the very slot written earlier in the region; use boxed objects to
// exercise forwarding without converting away an integer/double load guard.
function forward(o, value) { var b = o.y; o.x = value; var a = o.x; o.y = b; var c = o.y; return memorySink(a); }
var left = {x: null, y: 0};
var boxA = {value: 1}, boxB = {value: 2};
for (var i = 0; i < 500; i++) check(forward(left, i & 1 ? boxA : boxB) === (i & 1 ? boxA : boxB), 'same slot');

// A write to a distinct fixed slot on the same object leaves x unchanged.
function disjoint(o, value) { var before = o.x; o.y = value; var after = o.x; var extra = o.y; return memorySink(before + after + extra - value); }
var pair = {x: 7, y: 0};
for (var i = 0; i < 500; i++) check(disjoint(pair, i) === 14 && pair.y === i, 'different slots');

// Two different SSA inputs can refer to the same physical object.
function alias(a, b, value) { var before = a.x; b.x = value; var after = a.x; var extra = b.x; return memorySink(before + after + extra - value); }
var obj = {x: 4}, other = {x: 100};
for (var i = 0; i < 500; i++) {
  obj.x = 4; other.x = 100;
  check(alias(obj, other, 6) === 8 && other.x === 6, 'different objects');
  obj.x = 4;
  check(alias(obj, obj, 6) === 10 && obj.x === 6, 'same object alias');
}

// No value from one arm may be forwarded through a join on the other arm.
function branches(o, yes, value) { var before = o.x; if (yes) o.x = value; else o.y = value; var after = o.x; return memorySink(before + after); }
for (var i = 0; i < 500; i++) {
  pair.x = 7; pair.y = 0;
  check(branches(pair, false, 9) === 14 && pair.y === 9, 'untaken write');
  pair.x = 7;
  check(branches(pair, true, 9) === 16 && pair.x === 9, 'taken write');
}

// A late accessor must observe a completed write once when the region exits.
function late(o, value) { o.x = value; var q = o.x; var y = o.y; var result = o.late; return memorySink(result + q - value + y); }
var getterCalls = 0, recovered = {x: 0, y: 0, late: 2};
for (var i = 0; i < 500; i++) check(late(recovered, i) === 2 && recovered.x === i, 'late warm');
Object.defineProperty(recovered, 'late', {get: function () { getterCalls++; return this.x + 1; }, configurable: true});
check(late(recovered, 41) === 42 && recovered.x === 41 && getterCalls === 1, 'late getter');
print('effect memory CSE ok');

// Queue-style prefix: the read of queue after storing it must see the new
// value. A later getter sees the completed queue/state effects exactly once.
function prefixQueue(o) {
  var packet;
  if (o.state == 3) {
    packet = o.queue;
    o.queue = packet.link;
    if (o.queue == null) o.state = 0;
    else o.state = 1;
  } else { packet = null; }
  return o.task.run(packet);
}
var tail = {link: null}, head = {link: tail};
var effectTask = {run: function (packet) { return packet; }};
var queued = {state: 3, queue: head, task: effectTask};
for (var i = 0; i < 500; i++) {
  queued.state = 3; queued.queue = head;
  check(prefixQueue(queued) === head && queued.queue === tail && queued.state === 1, 'queue prefix');
}
var getterCount = 0;
Object.defineProperty(effectTask, 'run', {get: function () {
  getterCount++;
  check(queued.queue === null && queued.state === 0, 'getter observes completed writes');
  return function (packet) { return packet; };
}, configurable: true});
queued.state = 3; queued.queue = tail;
check(prefixQueue(queued) === tail && queued.queue === null && queued.state === 0 && getterCount === 1, 'queue getter');
print('effect memory recovery ok');
