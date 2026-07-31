// Queue
// FIFO semantics with enqueue/dequeue.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function Queue() { this.items = []; }
Queue.prototype.enqueue = function (v) { this.items.push(v); };
Queue.prototype.dequeue = function () { return this.items.shift(); };
Queue.prototype.front = function () { return this.items[0]; };
Queue.prototype.size = function () { return this.items.length; };
Queue.prototype.isEmpty = function () { return this.items.length === 0; };

var q = new Queue();
assert(q.isEmpty(), "new queue empty");

q.enqueue(1);
q.enqueue(2);
q.enqueue(3);
assert(q.size() === 3, "size after enqueues");
assert(q.front() === 1, "front is 1");

assert(q.dequeue() === 1, "dequeue 1");
assert(q.dequeue() === 2, "dequeue 2");
assert(q.front() === 3, "front is now 3");

// BFS on a small graph
var adj = {
    A: ["B", "C"],
    B: ["D", "E"],
    C: ["F"],
    D: [], E: [], F: []
};

function bfs(graph, start) {
    var visited = [];
    var queue = new Queue();
    queue.enqueue(start);
    while (!queue.isEmpty()) {
        var node = queue.dequeue();
        if (visited.indexOf(node) !== -1) continue;
        visited.push(node);
        var neighbors = graph[node] || [];
        for (var i = 0; i < neighbors.length; i++) {
            queue.enqueue(neighbors[i]);
        }
    }
    return visited;
}

var order = bfs(adj, "A");
assert(order.length === 6, "bfs visits 6 nodes");
assert(order[0] === "A", "bfs starts at A");

print("engine/queue: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");