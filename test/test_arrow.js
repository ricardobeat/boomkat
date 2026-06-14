var arrowObj = {
    val: 42,
    setup: function() {
        return () => this.val;
    }
};
var fn = arrowObj.setup();
print(typeof fn);
var result = fn();
print(result);
