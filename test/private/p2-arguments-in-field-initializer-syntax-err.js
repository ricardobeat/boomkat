// P2: `arguments` is not allowed inside a class field initializer — the
// initializer is its own function body with no `arguments` binding.
class A {
    x = arguments;
}
