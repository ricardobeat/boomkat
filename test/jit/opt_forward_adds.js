// An inlined constructor whose base constructor runs through a forwarded call
// (`_super.call(this, ...)`): the base's add names the object being built by a copy of its node,
// and must be accounted for as an add to that object (OptBuild.add_known), or the constructor's
// own adds that follow store into slots and shapes that leave the base's property out. Objects
// that add `value` first give the empty shape the transition such a stale add would take.
var __extends = function (d, b) { function __() { this.constructor = d; } __.prototype = b.prototype; d.prototype = new __(); };
var TS = {};
(function (TS) {
    TS.TokenID = { NumberLiteral: 109 };
    var TokenID = TS.TokenID;
    var Token = (function () { function Token(tokenId) { this.tokenId = tokenId; } return Token; })();
    var NumberLiteralToken = (function (_super) {
        __extends(NumberLiteralToken, _super);
        function NumberLiteralToken(value, hasEmptyFraction) {
            _super.call(this, TokenID.NumberLiteral);
            this.value = value;
            this.hasEmptyFraction = hasEmptyFraction;
        }
        return NumberLiteralToken;
    })(Token);
    TS.NumberLiteralToken = NumberLiteralToken;
    function Other() { this.value = 1; this.hasEmptyFraction = 2; }
    for (var j = 0; j < 3; j++) new Other();
    function make(v, two) {
        var s = "x" + v;
        if (two) return new TS.NumberLiteralToken(parseFloat(s.substring(1)), v > 5);
        return new TS.NumberLiteralToken(parseFloat(s.substring(1)));
    }
    var sum = 0, keys = "";
    for (var i = 0; i < 40000; i++) {
        var t = make(i % 10, i < 20000 || (i & 1));
        sum = (sum + t.tokenId + t.value + (t.hasEmptyFraction ? 1 : 0)) | 0;
        if (i % 9999 === 0) keys += Object.keys(t).join(",") + ";";
    }
    print(sum, keys);
})(TS);
