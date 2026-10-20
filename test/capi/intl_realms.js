// Intl internal-slot brands remain valid when a borrowed method enters another realm.
var realm = $262.createRealm();
var foreign = realm.global;
function checkIntlBrands(provider, owner) {
    var locale = new owner.Intl.Locale('en-US');
    var language = Object.getOwnPropertyDescriptor(provider.Intl.Locale.prototype, 'language').get;
    assert.sameValue(language.call(locale), 'en');
    assert.sameValue(provider.Intl.Locale.prototype.toString.call(locale), 'en-US');
    assert.sameValue(new provider.Intl.Locale(locale).toString(), 'en-US');
    assert.sameValue(new provider.Intl.NumberFormat(locale).resolvedOptions().locale, 'en-US');
    assert.sameValue(provider.Intl.NumberFormat.supportedLocalesOf([locale])[0], 'en-US');

    var list = new owner.Intl.ListFormat('en');
    assert.sameValue(provider.Intl.ListFormat.prototype.format.call(list, ['a', 'b']), 'a and b');
    assert.sameValue(provider.Intl.ListFormat.prototype.resolvedOptions.call(list).locale, 'en');
    var names = new owner.Intl.DisplayNames('en', { type: 'region' });
    assert.sameValue(provider.Intl.DisplayNames.prototype.of.call(names, 'US'), 'United States');
    var duration = new owner.Intl.DurationFormat('en', { style: 'digital' });
    assert.sameValue(provider.Intl.DurationFormat.prototype.format.call(duration, { seconds: 3 }), '0:00:03');

    var collator = new owner.Intl.Collator('en', { numeric: true });
    var compare = Object.getOwnPropertyDescriptor(provider.Intl.Collator.prototype, 'compare').get;
    assert.sameValue(compare.call(collator)('2', '10') < 0, true);
    assert.sameValue(provider.Intl.Collator.prototype.resolvedOptions.call(collator).numeric, true);

    var segmenter = new owner.Intl.Segmenter('en', { granularity: 'word' });
    assert.sameValue(provider.Intl.Segmenter.prototype.segment.call(segmenter, 'hello').containing(0).segment, 'hello');
    var segments = segmenter.segment('hello world');
    var providerSegments = new provider.Intl.Segmenter('en', { granularity: 'word' }).segment('x');
    var segmentsProto = Object.getPrototypeOf(providerSegments);
    assert.sameValue(segmentsProto.containing.call(segments, 7).segment, 'world');
    var iterator = segmentsProto[Symbol.iterator].call(segments);
    var providerIterator = providerSegments[Symbol.iterator]();
    var next = Object.getPrototypeOf(providerIterator).next;
    assert.sameValue(next.call(iterator).value.segment, 'hello');
    assert.sameValue(next.call(iterator).value.segment, ' ');
}
for (var round = 0; round < 4; round++) {
    checkIntlBrands(foreign, globalThis);
    checkIntlBrands(globalThis, foreign);
    var pressure = [];
    for (var i = 0; i < 200; i++) pressure.push({ locale: new Intl.Locale('en'), parts: ['a', 'b'] });
}
// An inherited prototype cannot substitute for the Intl internal slots.
assert.throws(foreign.TypeError, function () {
    foreign.Intl.ListFormat.prototype.format.call(Object.create(Intl.ListFormat.prototype), ['a']);
});
