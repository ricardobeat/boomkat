// A computed key or a `void`/`typeof` operand that is a variable's own
// register must be read as a value: coercing the key or deleting the operand
// must leave the variable alone.
var passed = 0;

function check(name, actual, expected) {
    if (actual !== expected) {
        throw new Error(name + ": expected " + expected + ", got " + actual);
    }
    passed++;
}

function dataKeys() {
    var c = 0;
    var o = { [++c]: ++c, [c++]: c++, [c]: (c += 10), [c]: c };
    return JSON.stringify(o) + ":" + typeof c + c;
}
check("data property keys are ToPropertyKey copies",
    dataKeys(), '{"1":2,"2":3,"4":14,"14":14}:number14');

function accessorKeys() {
    var k = 1;
    var o = { get [k]() { return "g"; }, set [k](v) {} };
    return typeof k + Object.keys(o).join();
}
check("accessor keys leave the variable a number", accessorKeys(), "number1");

// Top-level vars of a script live in registers when nothing else can read them.
var top = 0;
var topObj = { [++top]: ++top, [top]: (top += 10) };
check("top-level keys", JSON.stringify(topObj) + top, '{"1":2,"2":12}12');

function deleteNonReference() {
    var a = 5;
    var o = { x: 1 };
    return [delete void a, delete typeof a, delete void o.x, delete typeof o.x, a, o.x].join();
}
check("delete of void/typeof is not a reference", deleteNonReference(), "true,true,true,true,5,1");

function deleteNonReferenceStrict() {
    "use strict";
    var a = 5;
    return [delete void a, delete typeof a].join();
}
check("strict delete of void/typeof compiles", deleteNonReferenceStrict(), "true,true");

var classKey = 1;
class Fields { [classKey]() {} static [classKey] = 2; [classKey + 1] = 3; }
check("computed fields add no prototype property",
    Object.getOwnPropertyNames(Fields.prototype).join(), "1,constructor");
check("computed static fields add no constructor property",
    Object.getOwnPropertyNames(Fields).join(), "1,length,name,prototype");
check("computed instance field installs", new Fields()[2], 3);

print("computed_key_local_register: " + passed + " passed");
