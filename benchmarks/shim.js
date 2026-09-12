// Host shim for engines whose CLI lacks the Duktape/QuickJS `print` builtin.
// Prepended to each benchmark for Boa and Kiesel so they run the exact same
// source as the other engines. Keep this minimal: anything defined here is
// work the other engines don't do, so it must stay off the measured path.
var print = function () {
    console.log.apply(console, arguments);
};
