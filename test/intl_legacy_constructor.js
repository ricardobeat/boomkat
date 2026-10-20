function check(value, message) { if (!value) throw new Error(message); }
function throws(Type, fn) {
    try { fn(); } catch (e) { if (e instanceof Type) return; throw e; }
    throw new Error('expected ' + Type.name);
}
let shared;
for (const C of [Intl.NumberFormat, Intl.DateTimeFormat]) {
    const outer = Object.create(C.prototype);
    const result = C.call(outer, 'en', C === Intl.DateTimeFormat ? {timeZone: 'UTC'} : {});
    check(result === outer, 'constructor returns receiver');
    const symbols = Object.getOwnPropertySymbols(outer);
    check(symbols.length === 1, 'one fallback symbol');
    const sym = symbols[0];
    check(sym.description === 'IntlLegacyConstructedSymbol', 'symbol description');
    check(Symbol.keyFor(sym) === undefined, 'symbol is private to realm');
    if (shared) check(shared === sym, 'services share fallback symbol');
    shared = sym;
    const descriptor = Object.getOwnPropertyDescriptor(outer, sym);
    check(!descriptor.writable && !descriptor.enumerable && !descriptor.configurable, 'immutable fallback property');
    check(descriptor.value instanceof C, 'initialized formatter');
    check(typeof outer.format(0) === 'string', 'bound formatting unwraps');
    check(outer.resolvedOptions().locale === 'en', 'resolved options unwraps');
    check(new Proxy(outer, {}).format(0) === outer.format(0), 'proxy unwraps once');
    throws(TypeError, () => outer.formatToParts(0));
    throws(TypeError, () => C.call(outer));
    throws(TypeError, () => C.call(Object.freeze(Object.create(C.prototype))));
    const poisoned = Object.create(C.prototype);
    Object.defineProperty(poisoned, sym, {get() { throw new RangeError('fallback'); }});
    throws(RangeError, () => poisoned.resolvedOptions());
    Object.defineProperty(C, Symbol.hasInstance, {get() { throw new Error('hasInstance'); }, configurable: true});
    check(typeof C.call(Object.create(C.prototype)).format(0) === 'string', 'OrdinaryHasInstance');
    delete C[Symbol.hasInstance];
}
print('Intl legacy constructors passed');
