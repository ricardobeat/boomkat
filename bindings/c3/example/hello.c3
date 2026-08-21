// Minimal embedding example for the native C3 binding (`bindings/c3/boomkat.c3`).
//
//     c3c build boomkat_example_c3 && ./out/boomkat_example_c3
module boomkat_example;

import boomkat;
import std::io;

fn int main() {
    JsRuntime rt;
    if (catch e = rt.open()) {
        io::eprintfn("could not start the engine: %s", e);
        return 1;
    }
    defer rt.close();

    io::printn("-- values --");

    // A computed value, read back as a C3 double.
    JsValue answer = rt.eval("const base = 40; base + 2")!!;
    io::printfn("40 + 2      = %g", rt.as_number(answer)!!);
    rt.release(answer);

    // Strings come back as UTF-8, astral characters included.
    JsValue greeting = rt.eval(`["hi", "there", "\u{1F600}"].join(" ")`)!!;
    io::printfn("joined      = %s", rt.as_string(greeting)!!);
    rt.release(greeting);

    // Anything else can be coerced the way String(v) would.
    JsValue squares = rt.eval("[1,2,3,4].map(n => n * n)")!!;
    io::printfn("squares     = %s (type %s)", rt.to_display_string(squares)!!, rt.type_of(squares));
    rt.release(squares);

    io::printn("\n-- errors --");

    // A syntax error surfaces as a C3 fault, with the message on the runtime.
    if (catch e = rt.eval("function (")) {
        io::printfn("compile     = %s: %s", e, rt.last_error());
    }

    // So does a thrown exception.
    if (catch e = rt.eval(`throw new RangeError("index out of bounds")`)) {
        io::printfn("throw       = %s: %s", e, rt.last_error());
    }

    // Faults are ordinary values, so a JS error can be turned into a C3 one.
    double? parsed = read_number(&rt, "JSON.parse('{\"n\": 7}').n");
    io::printfn("parsed      = %g", parsed!!);
    double? missing = read_number(&rt, "notDefinedAnywhere");
    if (catch e = missing) io::printfn("undefined   = %s: %s", e, rt.last_error());

    // The runtime survives a failed eval and keeps its state.
    JsValue after = rt.eval("base * 10")!!;
    io::printfn("still alive = %g", rt.as_number(after)!!);
    rt.release(after);

    return 0;
}

// Evaluating and reading in one step: both failures propagate as C3 faults.
fn double? read_number(JsRuntime* rt, String source) {
    JsValue v = rt.eval(source)!;
    defer rt.release(v);
    return rt.as_number(v);
}
