// Generics on function declarations (no call-site type args).
function identity<T>(x: T): T {
    return x;
}

function pair<A, B>(a: A, b: B): { first: A, second: B } {
    return { first: a, second: b };
}

print(identity(42));
print(pair("hi", 7).first);
