function select(value) {
    return ({a: value, b: (value = 9), a: value + 1}).a;
}
select(4);
