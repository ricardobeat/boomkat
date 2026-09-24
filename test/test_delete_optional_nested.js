var observed = "unset";
if (delete (observed = null?.x) !== true || observed !== undefined) {
    print("FAIL: optional chain inside assignment");
}

var obj = {x: 1};
if (delete obj?.x !== true || "x" in obj) print("FAIL: direct optional delete");
obj.x = 2;
if (delete (obj?.["x"]) !== true || "x" in obj) print("FAIL: grouped optional delete");
if (delete null?.x !== true) print("FAIL: short-circuit optional delete");

var nestedKey = {"true": 4};
var nestedTarget = {y: 5};
delete nestedKey?.[delete nestedTarget?.y];
if ("true" in nestedKey || "y" in nestedTarget) {
    print("FAIL: optional delete with a nested delete key");
}

var other = {y: 3};
delete (null?.x, other?.y);
if (other.y !== 3) print("FAIL: optional chain inside comma expression");

var boxed;
delete (boxed = {x: null?.q}).x;
if (boxed.x !== undefined) print("FAIL: optional chain inside object value");

try {
    delete (null?.x).y;
    print("FAIL: grouped chain member did not throw");
} catch (error) {
    if (!(error instanceof TypeError)) print("FAIL: grouped chain member error");
}
