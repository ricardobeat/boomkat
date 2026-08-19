# ES6+ benchmarks (boomkat vs QuickJS only)

Duktape is ES5.1 and cannot parse `let`, arrow functions, classes, `for...of`,
template literals, destructuring, `Map`/`Set`, or generators. The main
`benchmarks/` suite is therefore written in ES5 so all three engines can run it.

That constraint left a hole. Not one of the 24 ES5 benchmarks uses a `let`/`const`
loop, and exactly one uses a closure — so the entire capture-analysis and
lexical-environment path is invisible to it. Work that measured 3-10x on those
paths moved the ES5 table by 1-3%, which is a property of the suite rather than
of the work.

These files fill that hole. They are timed against QuickJS alone, which is the
engine boomkat is actually behind on for modern JS.

Same conventions as the parent suite: a bare script, no output, timed
externally, sized to run in roughly 100-500ms so a real change is visible above
process startup.

Run with:

    just bench-es6
