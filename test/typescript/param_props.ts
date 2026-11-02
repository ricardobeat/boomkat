class Point {
    constructor(public x: number, public y: number) {}
    sum(): number { return this.x + this.y; }
}
let p = new Point(1, 2);
print(p.x);
print(p.sum());
