// The JS demo the sketch runs. The host exposes `lcd` and `millis()`; the
// sketch calls frame(t) in a loop once the script has run.
static const char DEMO_JS[] = R"JS(
const W = lcd.width, H = lcd.height;
const BLACK = 0, WHITE = lcd.rgb(255, 255, 255);

function hsv(h, s, v) {
  const i = Math.floor(h * 6), f = h * 6 - i;
  const p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s);
  const [r, g, b] = [[v, t, p], [q, v, p], [p, v, t], [p, q, v], [t, p, v], [v, p, q]][i % 6];
  return lcd.rgb(r * 255, g * 255, b * 255);
}

// Splash
lcd.fill(BLACK);
for (let y = 0; y < H; y += 4) lcd.rect(0, y, W, 4, hsv(y / H, 0.8, 0.35));
lcd.text("boomkat", 28, 110, WHITE, 4);
lcd.text("JavaScript on ESP32-C5", 32, 160, WHITE, 1);
lcd.text("rv32imac / 240MHz", 66, 176, lcd.rgb(180, 180, 180), 1);
delay(2000);

lcd.fill(BLACK);
lcd.text("touch to paint", 8, H - 16, lcd.rgb(150, 150, 150), 1);

// Animation: orbiting dots; touch paints
const dots = [];
for (let i = 0; i < 12; i++) dots.push({ a: i / 12 * Math.PI * 2, r: 30 + i * 5, x: 0, y: 0 });
let frames = 0, last = millis();

function frame(t) {
  for (const d of dots) {
    lcd.circle(d.x, d.y, 4, BLACK);
    d.a += 0.04 + d.r / 3000;
    d.x = W / 2 + Math.cos(d.a) * d.r;
    d.y = H / 2 - 40 + Math.sin(d.a) * d.r;
    lcd.circle(d.x, d.y, 4, hsv((d.a / (Math.PI * 2)) % 1, 1, 1));
  }
  const p = lcd.touch();
  if (p) lcd.circle(p[0], p[1], 6, hsv((t / 3000) % 1, 1, 1));
  frames++;
  if (t - last >= 1000) {
    lcd.rect(W - 64, 0, 64, 12, BLACK);
    lcd.text(`${frames} fps`, W - 60, 2, WHITE, 1);
    frames = 0;
    last = t;
  }
}
)JS";
