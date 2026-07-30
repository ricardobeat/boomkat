// Test 11: Colord — ESM color manipulation library
import { colord } from '../../vendor/colord.esm.js';

var c = colord('#ff0000');
if (!c.isValid()) throw 'colord("#ff0000").isValid() should be true';

var hex = c.toHex();
if (hex !== '#ff0000') throw 'Expected #ff0000, got ' + hex;

var rgb = c.toRgb();
if (rgb.r !== 255 || rgb.g !== 0 || rgb.b !== 0) throw 'toRgb() mismatch';

var hsl = c.toHsl();
if (hsl.h !== 0 || hsl.s !== 100 || hsl.l !== 50) throw 'toHsl() mismatch';

var light = c.lighten(0.2);
if (light.toHex() !== '#ff6666') throw 'Expected #ff6666 from lighten, got ' + light.toHex();

var dark = c.darken(0.2);
if (dark.toHex() !== '#990000') throw 'Expected #990000 from darken, got ' + dark.toHex();

var gray = c.grayscale();
if (gray.toHex() !== '#808080') throw 'Expected #808080 from grayscale, got ' + gray.toHex();

var inverted = c.invert();
var invHex = inverted.toHex();
if (invHex !== '#00ffff') throw 'Expected #00ffff from invert, got ' + invHex;

var blue = colord('#0000ff');
var rotated = blue.rotate(120);
if (rotated.toHex() !== '#ff0000') throw 'Expected #ff0000 from rotate(120), got ' + rotated.toHex();

// Named colors ("red", "rebeccapurple", …) come from colord's separate
// `names` plugin, which this bundle does not include — an unparsed input
// yields an invalid color, not a throw. Node agrees; asserting the parsed
// value here would be asserting a plugin that isn't loaded.
var named = colord('red');
if (named.isValid()) throw 'colord("red") should be invalid without the names plugin';

// Alpha
var alpha = colord('rgba(255, 0, 0, 0.5)');
var a = alpha.alpha();
if (a !== 0.5) throw 'alpha() expected 0.5, got ' + a;
