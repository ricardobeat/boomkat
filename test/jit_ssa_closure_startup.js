// Sixteen prototype initializers give the factory more than 64 registers.
// Its first CLOSURE must define/import the constructor before native code
// publishes the frame for DECLGLOBALFUNC and the first prototype read.
function closureStartupFactory() {
    function StartupProduct(value) { this.value = value; }
    return StartupProduct.prototype.m0 = 7,
        StartupProduct.prototype.m1 = 7,
        StartupProduct.prototype.m2 = 7,
        StartupProduct.prototype.m3 = 7,
        StartupProduct.prototype.m4 = 7,
        StartupProduct.prototype.m5 = 7,
        StartupProduct.prototype.m6 = 7,
        StartupProduct.prototype.m7 = 7,
        StartupProduct.prototype.m8 = 7,
        StartupProduct.prototype.m9 = 7,
        StartupProduct.prototype.m10 = 7,
        StartupProduct.prototype.m11 = 7,
        StartupProduct.prototype.m12 = 7,
        StartupProduct.prototype.m13 = 7,
        StartupProduct.prototype.m14 = 7,
        StartupProduct.prototype.m15 = 7,
        StartupProduct;
}
for (var startupRound = 0; startupRound < 128; startupRound++) {
    var StartupConstructor = closureStartupFactory();
    var startupProduct = new StartupConstructor(startupRound);
    if (startupProduct.value !== startupRound || startupProduct.m15 !== 7) {
        throw new Error('native closure startup result');
    }
}
