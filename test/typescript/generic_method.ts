class Container {
    wrap<T>(x: T): T[] {
        return [x];
    }
}
let c = new Container();
let a = c.wrap(3);
print(a[0]);
let b = c.wrap("hi");
print(b[0]);
