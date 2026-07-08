type Pair<A, B> = { first: A; second: B };
type Box<T> = { value: T };
let n: Box<Pair<number, string>> = { value: { first: 1, second: "two" } };
print(n.value.first);
print(n.value.second);
