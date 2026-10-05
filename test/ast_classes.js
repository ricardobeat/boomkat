function check(actual, expected) {
    if (actual !== expected) throw new Error(actual + ' !== ' + expected);
}

(function () {
    var events = [];
    class Base {
        constructor(value) { this.value = value; }
        method() { return this.value; }
        static method() { return 3; }
    }
    class Derived extends Base {
        #value = this.value + 1;
        #method() { return this.#value; }
        get #accessor() { return this.#method(); }
        set #accessor(value) { this.#value = value; }
        [events.push('key') && 'field'] = (events.push('field'), this.#accessor);
        static count = (events.push('static'), super.method());
        static { events.push('block'); this.count++; }
        constructor(...args) { super(...args); }
        method() { return super.method() + this.#method(); }
        read(other) { return other?.#value; }
        has(other) { return #value in other; }
        write(value) { this.#accessor = value; return this.#value++; }
        assign(source) { ({value: this.#value} = source); return this.#value; }
        *values() { yield this.#value; }
    }
    check(events.join(','), 'key,static,block');
    var value = new Derived(4);
    check(value.field, 5);
    check(value.method(), 9);
    check(Derived.count, 4);
    check(value.read(null), undefined);
    check(value.read(value), 5);
    check(value.has(value), true);
    check(value.has({}), false);
    check(value.write(8), 8);
    check(value.assign({value: 11}), 11);
    check(value.values().next().value, 11);
    check(events.join(','), 'key,static,block,field');
    var Named = class Inner { static own = Inner; self() { return Inner; } };
    check(Named.own, Named);
    check(new Named().self(), Named);
    check(typeof Inner, 'undefined');
    check(Named.name, 'Inner');
    var inferred = class { static own = this; };
    check(inferred.name, 'inferred');
    check(inferred.own, inferred);
    var base = {constructor: Object, method() { return 7; }};
    Object.setPrototypeOf(Derived.prototype, base);
    check(value.method(), 18);
})();
print('ast_classes: PASS');
