// Unique __super__ bindings: sibling classes in one scope each get their own
// numbered binding, so the last `extends` clause cannot clobber an earlier
// class's super resolution (the typescript services bundle hit this: ~10
// sibling classes, super() resolved to the wrong prototype object).

function expect(name, actual, expected) {
    print(name + ": " + (actual === expected ? "ok" : "FAIL got=" + String(actual) + " want=" + String(expected)));
}

// --- Sibling classes with extends in one function scope ---
function siblings() {
    var Base1 = class { constructor(v) { this.tag = "b1:" + v; } };
    var Base2 = class { constructor(v) { this.tag = "b2:" + v; } };
    class A extends Base1 {
        constructor() { super("a"); }
        get t() { return "A/" + this.tag; }
    }
    class B extends Base2 {
        constructor() { super("b"); }
        get t() { return "B/" + this.tag; }
    }
    // A late class must not retro-break A's already-created constructor.
    class C extends Base2 {
        constructor() { super("c"); }
        get t() { return "C/" + this.tag; }
    }
    return [new A().t, new B().t, new C().t].join(",");
}
expect("sibling ctors", siblings(), "A/b1:a,B/b2:b,C/b2:c");

// --- super.x methods and static super.x across sibling classes ---
class MBase { m() { return "M"; } static s() { return "MS"; } }
class NBase { m() { return "N"; } static s() { return "NS"; } }
class M extends MBase {
    m2() { return "M2" + super.m(); }
    static s2() { return "MS2" + super.s(); }
}
class N extends NBase {
    m2() { return "N2" + super.m(); }
    static s2() { return "NS2" + super.s(); }
}
expect("method super.x", new M().m2(), "M2M");
expect("method super.x late", new N().m2(), "N2N");
expect("static super.x", M.s2(), "MS2MS");
expect("static super.x late", N.s2(), "NS2NS");

// --- super inside a field-initializer arrow (separate init context) ---
class FBase { greeting() { return "hello"; } }
class F extends FBase {
    f = () => super.greeting() + "!";
    g = () => super.greeting() + "?";
}
class F2 extends FBase {
    f = () => super.greeting() + "2";
}
expect("field arrow super", new F().f(), "hello!");
expect("field arrow super 2", new F().g(), "hello?");
expect("field arrow super late", new F2().f(), "hello2");

// --- super inside a static block ---
class SBase { static name_() { return "SB"; } }
class S1 extends SBase {
    static out;
    static { S1.out = super.name_(); }
}
class S2 extends SBase {
    static out;
    static { S2.out = super.name_() + "2"; }
}
expect("static block super", S1.out, "SB");
expect("static block super late", S2.out, "SB2");

// --- super via direct eval in a method ---
class EBase { val() { return 41; } }
class E extends EBase {
    m() { return eval("super.val()") + 1; }
}
class E2 extends EBase {
    m() { return eval("super.val()") + 2; }
}
expect("eval super.x", new E().m(), 42);
expect("eval super.x late", new E2().m(), 43);

// --- super() argument evaluation order + IsConstructor TypeError ---
// Args are evaluated before the constructibility check (ES2024 super-keyword).
var orderEvaluated = false;
var orderCaught;
class O extends Object {
    constructor() {
        try { super(orderEvaluated = true); } catch (err) { orderCaught = err; }
    }
}
Object.setPrototypeOf(O, parseInt);
try { new O(); } catch (_) {}
expect("order args first", orderEvaluated, true);
expect("order TypeError", orderCaught instanceof TypeError, true);
Object.setPrototypeOf(O, Object); // restore for any later use

// --- Object-literal method super AFTER a class in the same scope ---
var olBase = { greet() { return "olb"; } };
var ol = {
    greet() { return "ol+" + olBase.greet.call(this) && "ok"; }
};
var obj = Object.create(olBase);
obj.method = function () { return "wrapped"; };
expect("obj literal after class", typeof ol.greet, "function");

// Object-literal method with a real HomeObject super, defined after classes.
var homeObj = {
    __proto__: { base() { return "hb"; } },
    derived() { return "d:" + super.base(); }
};
expect("obj literal super after class", homeObj.derived(), "d:hb");

// --- Nested classes: inner class in a method of an outer class ---
class Outer {
    run() {
        class InnerBase { v() { return "ib"; } }
        class Inner extends InnerBase {
            v() { return "i:" + super.v(); }
        }
        return new Inner().v();
    }
}
expect("nested class super", new Outer().run(), "i:ib");

print("done");
