// Conway's Game of Life — glider and blinker on a toroidal grid
// Exercises: classes, 2D arrays, nested loops, string building, closures

class Life {
    constructor(w, h) {
        this.w = w;
        this.h = h;
        this.cells = [];
        for (let i = 0; i < w * h; i++) this.cells[i] = 0;
    }

    set(x, y, v) {
        if (x >= 0 && x < this.w && y >= 0 && y < this.h) {
            this.cells[y * this.w + x] = v ? 1 : 0;
        }
    }

    get(x, y) {
        let wx = ((x % this.w) + this.w) % this.w;
        let wy = ((y % this.h) + this.h) % this.h;
        return this.cells[wy * this.w + wx];
    }

    neighbors(x, y) {
        let count = 0;
        for (let dy = -1; dy <= 1; dy++) {
            for (let dx = -1; dx <= 1; dx++) {
                if (dx === 0 && dy === 0) continue;
                count += this.get(x + dx, y + dy);
            }
        }
        return count;
    }

    step() {
        let next = [];
        for (let i = 0; i < this.w * this.h; i++) next[i] = 0;
        for (let y = 0; y < this.h; y++) {
            for (let x = 0; x < this.w; x++) {
                let n = this.neighbors(x, y);
                let alive = this.get(x, y);
                if (alive === 1) {
                    next[y * this.w + x] = (n === 2 || n === 3) ? 1 : 0;
                } else {
                    next[y * this.w + x] = (n === 3) ? 1 : 0;
                }
            }
        }
        this.cells = next;
    }

    countAlive() {
        let count = 0;
        for (let i = 0; i < this.w * this.h; i++) count += this.cells[i];
        return count;
    }

    render() {
        let out = "";
        for (let y = 0; y < this.h; y++) {
            let line = "";
            for (let x = 0; x < this.w; x++) {
                line += this.get(x, y) ? "O " : ". ";
            }
            out += line + "\n";
        }
        return out;
    }
}

// --- Test 1: Glider (spaceship, period 4) ---
var grid = new Life(20, 12);
// Glider: moves right+down every 4 generations
grid.set(1, 0, 1);
grid.set(2, 1, 1);
grid.set(0, 2, 1);
grid.set(1, 2, 1);
grid.set(2, 2, 1);

console.log("=== Conway's Game of Life ===");
console.log("Glider (gen 0):");
console.log(grid.render());

var initialAlive = grid.countAlive();

for (let gen = 1; gen <= 12; gen++) {
    grid.step();
    if (gen % 4 === 0) {
        console.log("Glider (gen " + gen + "):");
        console.log(grid.render());
    }
}

var finalAlive = grid.countAlive();
console.log("Glider alive: start=" + initialAlive + " end=" + finalAlive);

// --- Test 2: Blinker (oscillator, period 2) ---
var blinker = new Life(5, 5);
blinker.set(2, 1, 1);
blinker.set(2, 2, 1);
blinker.set(2, 3, 1);

blinker.step();
// Blinker should be horizontal: (1,2), (2,2), (3,2)
var b1 = blinker.get(1, 2) + blinker.get(2, 2) + blinker.get(3, 2);
var b1total = blinker.countAlive();

blinker.step();
// Back to vertical: (2,1), (2,2), (2,3)
var b2 = blinker.get(2, 1) + blinker.get(2, 2) + blinker.get(2, 3);
var b2total = blinker.countAlive();

console.log("Blinker after 1 step: row sum=" + b1 + " total=" + b1total);
console.log("Blinker after 2 steps: col sum=" + b2 + " total=" + b2total);

// --- Test 3: Still life (block, never changes) ---
var block = new Life(4, 4);
block.set(1, 1, 1);
block.set(2, 1, 1);
block.set(1, 2, 1);
block.set(2, 2, 1);
block.step();
var blockAlive = block.countAlive();

console.log("Block after 1 step: " + blockAlive);

// Verify
let pass = true;
if (initialAlive !== 5) pass = false;
if (finalAlive !== 5) pass = false;
if (b1total !== 3) pass = false;
if (b2total !== 3) pass = false;
if (blockAlive !== 4) pass = false;

console.log(pass ? "PASS" : "FAIL");
