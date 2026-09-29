var iteratorProto = Object.getPrototypeOf([][Symbol.iterator]());
var arrayProto = Array.prototype;
var originalArrayProtoParent = Object.getPrototypeOf(arrayProto);
var originalArrayIteratorDescriptor = Object.getOwnPropertyDescriptor(arrayProto, Symbol.iterator);
var originalDescriptor = Object.getOwnPropertyDescriptor(iteratorProto, "next");
var originalReturnDescriptor = Object.getOwnPropertyDescriptor(iteratorProto, "return");
var originalNext = originalDescriptor.value;

try {
    var calls = 0;
    iteratorProto.next = function () {
        calls++;
        return originalNext.call(this);
    };
    const [first, second] = [1, 2];
    if (first !== 1 || second !== 2 || calls !== 2) {
        throw new Error("array destructuring must call an overridden iterator next");
    }

    var getterCalls = 0;
    Object.defineProperty(iteratorProto, "next", {
        configurable: true,
        enumerable: originalDescriptor.enumerable,
        get: function () {
            getterCalls++;
            return originalNext;
        }
    });
    const [third, fourth] = [3, 4];
    if (third !== 3 || fourth !== 4 || getterCalls !== 1) {
        throw new Error("array destructuring must read an accessor next once");
    }

    Object.defineProperty(iteratorProto, "next", originalDescriptor);
    var closeCalls = 0;
    Object.defineProperty(iteratorProto, "return", {
        configurable: true,
        value: function () {
            closeCalls++;
            return {};
        }
    });
    const [fifth, sixth] = [5, 6];
    if (fifth !== 5 || sixth !== 6 || closeCalls !== 1) {
        throw new Error("array destructuring must close an iterator with return");
    }
    if (originalReturnDescriptor) {
        Object.defineProperty(iteratorProto, "return", originalReturnDescriptor);
    } else {
        delete iteratorProto.return;
    }

    var returnGetterCalls = 0;
    var returnCalls = 0;
    Object.defineProperty(iteratorProto, "return", {
        configurable: true,
        get: function () {
            returnGetterCalls++;
            return function () {
                returnCalls++;
                return {};
            };
        }
    });
    const [seventh, eighth] = [7, 8];
    if (seventh !== 7 || eighth !== 8 || returnGetterCalls !== 1 || returnCalls !== 1) {
        throw new Error("array destructuring must read iterator return once when closing");
    }
    if (originalReturnDescriptor) {
        Object.defineProperty(iteratorProto, "return", originalReturnDescriptor);
    } else {
        delete iteratorProto.return;
    }

    Object.defineProperty(iteratorProto, "return", {
        configurable: true,
        value: 1
    });
    var nonCallableReturnThrew = false;
    try {
        const [nonCallableFirst, nonCallableSecond] = [9, 10];
    } catch (error) {
        nonCallableReturnThrew = error instanceof TypeError;
    }
    if (!nonCallableReturnThrew) {
        throw new Error("array destructuring must reject a non-callable iterator return");
    }
    if (originalReturnDescriptor) {
        Object.defineProperty(iteratorProto, "return", originalReturnDescriptor);
    } else {
        delete iteratorProto.return;
    }

    const [shortFirst, shortSecond] = [9];
    if (shortFirst !== 9 || shortSecond !== undefined) {
        throw new Error("short array destructuring must supply undefined");
    }

    var indexedReads = 0;
    var indexed = [10, 11];
    Object.defineProperty(indexed, "0", {
        configurable: true,
        get: function () {
            indexedReads++;
            return 12;
        }
    });
    const [indexedFirst, indexedSecond] = indexed;
    if (indexedFirst !== 12 || indexedSecond !== 11 || indexedReads !== 1) {
        throw new Error("array destructuring must read indexed accessors");
    }

    var inheritedIndexReads = 0;
    var sparseProto = Object.create(arrayProto);
    Object.defineProperty(sparseProto, "0", {
        configurable: true,
        get: function () {
            inheritedIndexReads++;
            return 13;
        }
    });
    var sparse = new Array(2);
    sparse[1] = 14;
    Object.setPrototypeOf(sparse, sparseProto);
    const [sparseFirst, sparseSecond] = sparse;
    if (sparseFirst !== 13 || sparseSecond !== 14 || inheritedIndexReads !== 1) {
        throw new Error("array destructuring must read inherited getters for holes");
    }
} finally {
    Object.defineProperty(iteratorProto, "next", originalDescriptor);
    if (originalReturnDescriptor) {
        Object.defineProperty(iteratorProto, "return", originalReturnDescriptor);
    } else {
        delete iteratorProto.return;
    }
}

var iteratorProtoParent = Object.getPrototypeOf(iteratorProto);
var proxyNextReads = 0;
try {
    delete iteratorProto.next;
    Object.setPrototypeOf(iteratorProto, new Proxy(iteratorProtoParent, {
        get: function (target, key, receiver) {
            if (key === "next") {
                proxyNextReads++;
                return originalNext;
            }
            return Reflect.get(target, key, receiver);
        }
    }));
    const [proxyNextFirst, proxyNextSecond] = [15, 16];
    if (proxyNextFirst !== 15 || proxyNextSecond !== 16 || proxyNextReads !== 1) {
        throw new Error("array destructuring must perform one inherited proxy next lookup");
    }
} finally {
    Object.setPrototypeOf(iteratorProto, iteratorProtoParent);
    Object.defineProperty(iteratorProto, "next", originalDescriptor);
}

var proxyIteratorReads = 0;
var proxyWrongReceiver = false;
var proxySource = [13, 14];
try {
    delete arrayProto[Symbol.iterator];
    Object.setPrototypeOf(arrayProto, new Proxy(originalArrayProtoParent, {
        get: function (target, key, receiver) {
            if (key === Symbol.iterator) {
                proxyIteratorReads++;
                if (receiver !== proxySource) proxyWrongReceiver = true;
                return originalArrayIteratorDescriptor.value;
            }
            return Reflect.get(target, key, receiver);
        }
    }));
    const [proxyFirst, proxySecond] = proxySource;
    if (proxyFirst !== 13 || proxySecond !== 14 || proxyIteratorReads !== 1 || proxyWrongReceiver) {
        throw new Error("array destructuring must run an inherited proxy get once");
    }
} finally {
    Object.setPrototypeOf(arrayProto, originalArrayProtoParent);
    Object.defineProperty(arrayProto, Symbol.iterator, originalArrayIteratorDescriptor);
}

const [fastFirst, fastSecond] = [7, 8];
if (fastFirst !== 7 || fastSecond !== 8) {
    throw new Error("flat lexical array destructuring returned wrong values");
}

function captureFastBindings() {
    const [capturedFirst, capturedSecond] = [17, 18];
    return function () { return capturedFirst + capturedSecond; };
}
if (captureFastBindings()() !== 35) {
    throw new Error("flat lexical destructuring must initialize captured bindings");
}
