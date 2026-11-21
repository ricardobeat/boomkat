// three.js UltraHDR gain-map decode loop: Math.pow + sRGB->linear + toHalfFloat.
// Reduced from 2048x1024x3; three's DataUtils.toHalfFloat reproduced verbatim.
const _tables = (function () {
  const buffer = new ArrayBuffer(4);
  const floatView = new Float32Array(buffer);
  const uint32View = new Uint32Array(buffer);
  const baseTable = new Uint32Array(512);
  const shiftTable = new Uint32Array(512);
  for (let i = 0; i < 256; ++i) {
    const e = i - 127;
    if (e < -27) { baseTable[i] = 0x0000; baseTable[i | 0x100] = 0x8000; shiftTable[i] = 24; shiftTable[i | 0x100] = 24; }
    else if (e < -14) { baseTable[i] = 0x0400 >> (-e - 14); baseTable[i | 0x100] = (0x0400 >> (-e - 14)) | 0x8000; shiftTable[i] = -e - 1; shiftTable[i | 0x100] = -e - 1; }
    else if (e <= 15) { baseTable[i] = (e + 15) << 10; baseTable[i | 0x100] = ((e + 15) << 10) | 0x8000; shiftTable[i] = 13; shiftTable[i | 0x100] = 13; }
    else if (e < 128) { baseTable[i] = 0x7c00; baseTable[i | 0x100] = 0xfc00; shiftTable[i] = 24; shiftTable[i | 0x100] = 24; }
    else { baseTable[i] = 0x7c00; baseTable[i | 0x100] = 0xfc00; shiftTable[i] = 13; shiftTable[i | 0x100] = 13; }
  }
  return { floatView, uint32View, baseTable, shiftTable };
})();

function clamp(value, min, max) { return Math.max(min, Math.min(max, value)); }

function toHalfFloat(val) {
  if (Math.abs(val) > 65504) console.warn('toHalfFloat(): Value out of range.');
  val = clamp(val, -65504, 65504);
  _tables.floatView[0] = val;
  const f = _tables.uint32View[0];
  const e = (f >> 23) & 0x1ff;
  return _tables.baseTable[e] + ((f & 0x007fffff) >> _tables.shiftTable[e]);
}

function srgbToLinear(c) {
  return (c < 0.04045) ? c * 0.0773993808 : Math.pow(c * 0.9478672986 + 0.0521327014, 2.4);
}

function decode(sdr, gain, out, n) {
  const gamma = 1.0, offSdr = 1 / 64, offHdr = 1 / 64, minLog = 0, maxLog = 3.5, weight = 1;
  for (let i = 0; i < n; i++) {
    for (let c = 0; c < 3; c++) {
      const s = srgbToLinear(sdr[i * 4 + c] / 255);
      const g = Math.pow(gain[i * 4 + c] / 255, 1 / gamma);
      const logBoost = minLog * (1 - g) + maxLog * g;
      const hdr = (s + offSdr) * Math.pow(2, logBoost * weight) - offHdr;
      out[i * 4 + c] = toHalfFloat(hdr);
    }
    out[i * 4 + 3] = 0x3c00;
  }
}

const N = 512 * 1024;
const sdr = new Uint8ClampedArray(N * 4), gain = new Uint8ClampedArray(N * 4);
for (let i = 0; i < N * 4; i++) { sdr[i] = (i * 31) & 255; gain[i] = (i * 17) & 255; }
const out = new Uint16Array(N * 4);
decode(sdr, gain, out, N);
let sum = 0;
for (let i = 0; i < out.length; i += 97) sum += out[i];
print(sum);
