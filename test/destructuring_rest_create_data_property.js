// Array rest uses CreateDataProperty for each collected value (§13.3.3.6).
// It must not invoke a modified Array.prototype.push or inherited index setter.

var originalPush = Array.prototype.push;
var head, tail, pushThrew = false;
try {
    Array.prototype.push = function () { throw new Error("rest called push"); };
    [head, ...tail] = [0, 1, 2];
} catch (error) {
    pushThrew = true;
} finally {
    Array.prototype.push = originalPush;
}
if (pushThrew || head !== 0 || tail.length !== 2 || tail[0] !== 1 || tail[1] !== 2) {
    throw new Error("array rest must collect without calling Array.prototype.push");
}

var nestedFirst, nestedSecond;
[...[nestedFirst, nestedSecond]] = [3, 4, 5];
if (nestedFirst !== 3 || nestedSecond !== 4) {
    throw new Error("nested assignment rest must collect into its intermediate array");
}

function declarationRest() {
    const [declaredHead, ...declaredTail] = [6, 7, 8];
    return declaredHead === 6 && declaredTail.length === 2
        && declaredTail[0] === 7 && declaredTail[1] === 8;
}
if (!declarationRest()) {
    throw new Error("declaration rest must collect and bind the output array");
}

var holeTail;
[, ...holeTail] = [0, , 3];
var holeZero = Object.getOwnPropertyDescriptor(holeTail, "0");
if (holeTail.length !== 2 || !holeZero || holeZero.value !== undefined || holeTail[1] !== 3) {
    throw new Error("array rest must preserve holes as own undefined values");
}

var changing = [10, , 30];
var changingProto = Object.create(Array.prototype);
var inheritedReads = 0;
Object.defineProperty(changingProto, "1", {
    configurable: true,
    get: function () {
        inheritedReads++;
        changing.length = 2;
        return 20;
    }
});
Object.setPrototypeOf(changing, changingProto);
var changingHead, changingTail;
[changingHead, ...changingTail] = changing;
if (changingHead !== 10 || inheritedReads !== 1 || changingTail.length !== 1 || changingTail[0] !== 20) {
    throw new Error("array rest must observe indexed getters and live length changes");
}

var stringTail;
[...stringTail] = "A\u{1F600}B";
if (stringTail.length !== 3 || stringTail[0] !== "A" || stringTail[1] !== "\u{1F600}" || stringTail[2] !== "B") {
    throw new Error("array rest must preserve string iterator code points");
}

var mapTail;
[...mapTail] = new Map([[1, "a"], [2, "b"]]);
if (mapTail.length !== 2 || mapTail[0][0] !== 1 || mapTail[0][1] !== "a"
    || mapTail[1][0] !== 2 || mapTail[1][1] !== "b") {
    throw new Error("array rest must preserve map entry iterator values");
}

var iteratorProto = Object.getPrototypeOf([][Symbol.iterator]());
var originalNext = iteratorProto.next;
var nextCalls = 0;
var overriddenTail;
var nextThrew = false;
try {
    iteratorProto.next = function () {
        nextCalls++;
        return originalNext.call(this);
    };
    var ignored;
    [ignored, ...overriddenTail] = [0, 1, 2];
} catch (error) {
    nextThrew = true;
} finally {
    iteratorProto.next = originalNext;
}
if (nextThrew || nextCalls !== 4 || overriddenTail.length !== 2
    || overriddenTail[0] !== 1 || overriddenTail[1] !== 2) {
    throw new Error("array rest must call a patched iterator next method");
}

var arrayProto = Array.prototype;
var originalZero = Object.getOwnPropertyDescriptor(arrayProto, "0");
var setterCalls = 0;
var setterTail;
try {
    Object.defineProperty(arrayProto, "0", {
        configurable: true,
        set: function () { setterCalls++; }
    });
    [, ...setterTail] = [10, 11, 12];
} finally {
    if (originalZero) {
        Object.defineProperty(arrayProto, "0", originalZero);
    } else {
        delete arrayProto["0"];
    }
}
var zero = Object.getOwnPropertyDescriptor(setterTail, "0");
if (setterCalls !== 0 || !zero || zero.value !== 11 || setterTail[1] !== 12) {
    throw new Error("array rest must define own indexed data properties");
}

print("destructuring_rest_create_data_property: all checks passed");
