function select(source) {
    let result;
    { const copy = {...source, tail: 1}; result = copy.a; }
    return result;
}
function length(source) {
    let result;
    { const copy = [...source, 1]; result = copy.length; }
    return result;
}
select({a: 4});
length([1, 2]);
