(function () {
    function check(ok, label) { if (!ok) throw new Error(label); }
    var setters = ['setMilliseconds', 'setSeconds', 'setMinutes', 'setHours',
                   'setUTCMilliseconds', 'setUTCSeconds', 'setUTCMinutes', 'setUTCHours'];
    setters.forEach(function (name, index) {
        var count = index % 4 + 1, order = [], date = new Date(NaN);
        var args = [0, 1, 2, 3].map(function (value) {
            return { valueOf: function () { order.push(value); return value; } };
        });
        check(Number.isNaN(date[name].apply(date, args)), name + ' invalid clock');
        check(order.join() === [0, 1, 2, 3].slice(0, count).join(), name + ' coercion order');
        var marker = {}, caught;
        args[0] = { valueOf: function () { throw marker; } };
        try { date[name].apply(date, args); } catch (error) { caught = error; }
        check(caught === marker, name + ' argument exception');
    });
    ['find', 'findLast', 'findIndex', 'findLastIndex'].forEach(function (name, index) {
        var seen = [], receiver = {}, array = [10, , 30];
        var result = array[name](function (value, key, object) {
            check(this === receiver && object === array, name + ' callback arguments');
            seen.push(key);
            array.length = 0;
            return key === 1;
        }, receiver);
        check(seen.join() === (index % 2 ? '2,1' : '0,1'), name + ' snapshot length and direction');
        check(index < 2 ? result === undefined : result === 1, name + ' hole result');
        check(index < 2 ? [][name](function () {}) === undefined : [][name](function () {}) === -1,
              name + ' empty result');
    });
    check('x'.padStart(4, 'ab') === 'abax', 'padStart partial fill');
    check('x'.padEnd(4, 'ab') === 'xaba', 'padEnd partial fill');
    ['padStart', 'padEnd'].forEach(function (name) {
        var order = [];
        var result = String.prototype[name].call(
            { toString: function () { order.push('receiver'); return 'x'; } },
            { valueOf: function () { order.push('length'); return 1; } },
            { toString: function () { throw new Error('unneeded fill coercion'); } });
        check(result === 'x' && order.join() === 'receiver,length', name + ' early return');
    });
    print('shared builtin algorithms passed');
})();
