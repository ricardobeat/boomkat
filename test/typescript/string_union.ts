type Dir = "up" | "down" | "left" | "right";
let d: Dir = "up";
function step(dir: Dir): number {
    if (dir === "up") return 1;
    if (dir === "down") return -1;
    return 0;
}
print(step(d));
print(step("down"));
