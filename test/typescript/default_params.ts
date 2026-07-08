function greet(name: string = "world", greeting: string = "hi"): string {
    return greeting + " " + name;
}
print(greet());
print(greet("x"));
print(greet("x", "hey"));
