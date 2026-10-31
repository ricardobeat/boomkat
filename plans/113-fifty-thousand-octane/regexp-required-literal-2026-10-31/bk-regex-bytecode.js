var r = /(^|[^\\])"\\\/Qngr\((-?[0-9]+)\)\\\/"/;
print(r.test('plain input without the required substring'));
print(r.test('prefix "\\/Qngr(123)\\/"'));
