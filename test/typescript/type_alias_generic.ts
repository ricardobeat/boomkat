type Box<T> = { value: T };
let b: Box<number> = { value: 7 };
print(b.value);
