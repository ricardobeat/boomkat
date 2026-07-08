// Overload signatures (`function f(x): T;`) without a body are a documented
// gap — the parser doesn't yet skip a bodyless signature. Exercise the
// implementation-signature shape only, which is what actually runs.
function greet(name: string, age?: number): string {
    if (age === undefined) return "hi " + name;
    return "hi " + name + " " + age;
}
print(greet("a"));
print(greet("b", 3));
