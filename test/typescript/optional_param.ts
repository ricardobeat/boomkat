function tag(name: string, id?: number): string {
    if (id === undefined) return name;
    return name + "#" + id;
}
print(tag("a"));
print(tag("b", 2));
