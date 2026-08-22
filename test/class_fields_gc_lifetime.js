// GC lifetime of the receiver a native re-entry BORROWS.
//
// vm_call_fn_impl assigns Activation.this_binding raw and relies on the caller
// to hold the owning reference for the duration of the call. That keeps the
// refcount correct and says nothing about REACHABILITY, which is the property
// mark-and-sweep actually uses: the sweep frees every node the mark phase did
// not reach, whatever its refcount. So a receiver reachable only through such a
// frame was collected mid-call, and its address immediately recycled for an
// unrelated object.
//
// vm_init_private_members is the reproducing case. It hands the part-built
// instance to __field_init__ as exactly that kind of borrowed receiver: the
// object lives in no register and no environment the marker walks. A field
// initializer containing a direct eval then allocates (compiling the eval body),
// that allocation trips a safepoint collection, and the instance is swept while
// the constructor is still running. CHK_BRAND afterwards tests whatever object
// now occupies the address and throws a TypeError with no catcher above it,
// surfacing as a bare vm::VM_ERROR.
//
// This is a GC TIMING bug, not a scoping one. The same code inside a function
// appeared to work only because the collection happened to fire before the
// instance was allocated; the loops below allocate first precisely so the
// collection lands in the window that matters. Under GC_STRESS every allocation
// collects, so the window is always hit.
//
// The private member must be an ACCESSOR or a METHOD rather than a field: those
// are the ones reached through a brand check, which is what reads the recycled
// object and turns the freed receiver into an observable failure.

var pass = 0, fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); }
}

// Allocate ahead of each class so a collection is due while the constructor
// runs, then build many instances so at least one lands in the window.
function churn(n) {
    var pad = [];
    for (var i = 0; i < n; i++) { pad.push({ i: i, s: 'pad' + i }); }
    return pad.length;
}

churn(3000);
class Getter {
    get #m() { return 'getter'; }
    v = eval('this.#m');
}
for (var a = 0; a < 200; a++) {
    assert(new Getter().v === 'getter', 'private getter via eval in field initializer');
}

churn(3000);
class Method {
    #m() { return 'method'; }
    v = eval('this.#m()');
}
for (var b = 0; b < 200; b++) {
    assert(new Method().v === 'method', 'private method via eval in field initializer');
}

churn(3000);
class Setter {
    #stored = 0;
    set #m(x) { this.#stored = x; }
    v = (eval('this.#m = 41'), this.#stored + 1);
}
for (var c = 0; c < 200; c++) {
    assert(new Setter().v === 42, 'private setter via eval in field initializer');
}

// A brand check must still REJECT a foreign object: the fix publishes the
// receiver to the collector, and must not have made the check permissive.
churn(1000);
class Branded {
    get #m() { return 1; }
    static probe(o) {
        try { eval('o.#m'); return 'no-throw'; }
        catch (e) { return e.name; }
    }
}
assert(Branded.probe({}) === 'TypeError', 'brand check still rejects a foreign object');

// The same borrowed-receiver shape without private names: a getter invoked
// through the native call path while the receiver is reachable only from the
// frame. Guards the general fix rather than the private-member symptom.
churn(3000);
for (var d = 0; d < 200; d++) {
    var host = { _v: d, get val() { return this._v; } };
    assert(Object.getOwnPropertyDescriptor(host, 'val').get.call(host) === d,
        'getter called with a borrowed receiver');
}

// Array callbacks re-enter the VM with a borrowed `this` supplied by the
// builtin, another instance of the same pattern.
churn(3000);
for (var e = 0; e < 100; e++) {
    var thisArg = { base: e };
    var out = [1, 2].map(function (x) { return x + this.base; }, thisArg);
    assert(out[0] === e + 1 && out[1] === e + 2, 'map callback with a borrowed thisArg');
}

print('class_fields_gc_lifetime: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
