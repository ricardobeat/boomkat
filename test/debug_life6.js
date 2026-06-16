class Life {
    constructor(w, h) {
        this.w = w;
        this.h = h;
        this.cells = [];
        for (let i = 0; i < w * h; i++) this.cells[i] = 0;
    }
}

// One instance works
var x1 = new Life(3, 3);
console.log("x1.cells.len=" + x1.cells.length); // should be 9

// Second same-size instance
var x2 = new Life(3, 3);
console.log("x2.cells.len=" + x2.cells.length); // should be 9
console.log("x1.cells.len after x2=" + x1.cells.length); // should still be 9
