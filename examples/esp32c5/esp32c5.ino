// Runs a JavaScript demo through boomkat on the NM-CYD-C5 (ESP32-C5, 2.8"
// ST7789 240x320, XPT2046 resistive touch). JS draws through the `lcd` object
// defined here. Needs PSRAM. Build and flash with `just esp32c5-flash`.
#include <Arduino.h>
#include <LovyanGFX.hpp>
#include "boomkat.h"
#include "demo.h"

// From bk_newlib_shim.c; must run on the task that uses the engine.
extern "C" void bk_esp32_init(void);

// The default loopTask stack (8 KB) is too small for the parser and VM.
static const uint32_t ENGINE_STACK = 48 * 1024;

// Display, touch and SD share one SPI bus (SCLK 6, MOSI 7, MISO 2). The panel
// reset is tied to EN.
class CydC5 : public lgfx::LGFX_Device {
    lgfx::Panel_ST7789 panel;
    lgfx::Bus_SPI bus;
    lgfx::Light_PWM light;
    lgfx::Touch_XPT2046 touch;

public:
    CydC5()
    {
        auto b = bus.config();
        b.spi_host = SPI2_HOST;
        b.spi_mode = 0;
        b.freq_write = 40000000;
        b.freq_read = 16000000;
        b.pin_sclk = 6;
        b.pin_mosi = 7;
        b.pin_miso = 2;
        b.pin_dc = 24;
        bus.config(b);
        panel.setBus(&bus);

        auto p = panel.config();
        p.pin_cs = 23;
        p.pin_rst = -1;
        p.panel_width = 240;
        p.panel_height = 320;
        p.invert = true;
        p.bus_shared = true;
        panel.config(p);

        auto l = light.config();
        l.pin_bl = 25;
        l.invert = false;
        l.freq = 44100;
        l.pwm_channel = 0;
        light.config(l);
        panel.setLight(&light);

        auto t = touch.config();
        t.spi_host = SPI2_HOST;
        t.freq = 1000000;
        t.pin_sclk = 6;
        t.pin_mosi = 7;
        t.pin_miso = 2;
        t.pin_cs = 1;
        t.pin_int = 3;
        t.bus_shared = true;
        t.x_min = 3900;
        t.x_max = 300;
        t.y_min = 200;
        t.y_max = 3700;
        t.offset_rotation = 0;
        touch.config(t);
        panel.setTouch(&touch);

        setPanel(&panel);
    }
};

static CydC5 tft;

static int arg_int(bk_ctx js, unsigned i)
{
    double d = 0;
    bk_read_number(js, bk_arg(js, i), &d);
    return (int)d;
}

static bk_value lcd_fill(bk_ctx js, bk_value, unsigned, const bk_value *, void *)
{
    tft.fillScreen(arg_int(js, 0));
    return BK_UNDEFINED;
}

static bk_value lcd_rect(bk_ctx js, bk_value, unsigned, const bk_value *, void *)
{
    tft.fillRect(arg_int(js, 0), arg_int(js, 1), arg_int(js, 2), arg_int(js, 3), (uint16_t)arg_int(js, 4));
    return BK_UNDEFINED;
}

static bk_value lcd_circle(bk_ctx js, bk_value, unsigned, const bk_value *, void *)
{
    tft.fillCircle(arg_int(js, 0), arg_int(js, 1), arg_int(js, 2), (uint16_t)arg_int(js, 3));
    return BK_UNDEFINED;
}

static bk_value lcd_line(bk_ctx js, bk_value, unsigned, const bk_value *, void *)
{
    tft.drawLine(arg_int(js, 0), arg_int(js, 1), arg_int(js, 2), arg_int(js, 3), (uint16_t)arg_int(js, 4));
    return BK_UNDEFINED;
}

// text(str, x, y, color, size)
static bk_value lcd_text(bk_ctx js, bk_value, unsigned, const bk_value *, void *)
{
    const char *s = bk_cstr(js, bk_arg(js, 0), NULL);
    if (!s) return BK_EXCEPTION;
    int size = arg_int(js, 4);
    tft.setTextSize(size > 0 ? size : 1);
    tft.setTextColor((uint16_t)arg_int(js, 3));
    tft.drawString(s, arg_int(js, 1), arg_int(js, 2));
    return BK_UNDEFINED;
}

static bk_value lcd_rgb(bk_ctx js, bk_value, unsigned, const bk_value *, void *)
{
    return bk_new_number(js, tft.color565(arg_int(js, 0), arg_int(js, 1), arg_int(js, 2)));
}

// [x, y] while the panel is pressed, else null.
static bk_value lcd_touch(bk_ctx js, bk_value, unsigned, const bk_value *, void *)
{
    lgfx::touch_point_t tp;
    if (!tft.getTouch(&tp)) return BK_NULL;
    bk_value xy[2] = { bk_new_number(js, tp.x), bk_new_number(js, tp.y) };
    return bk_new_array_from(js, xy, 2);
}

static bk_value js_millis(bk_ctx js, bk_value, unsigned, const bk_value *, void *)
{
    return bk_new_number(js, millis());
}

static bk_value js_delay(bk_ctx js, bk_value, unsigned, const bk_value *, void *)
{
    delay(arg_int(js, 0));
    return BK_UNDEFINED;
}

static void install_api(bk_ctx js)
{
    bk_value lcd = bk_new_object(js);
    bk_register_fn(js, lcd, "fill", lcd_fill, 1, 0, NULL);
    bk_register_fn(js, lcd, "rect", lcd_rect, 5, 0, NULL);
    bk_register_fn(js, lcd, "circle", lcd_circle, 4, 0, NULL);
    bk_register_fn(js, lcd, "line", lcd_line, 5, 0, NULL);
    bk_register_fn(js, lcd, "text", lcd_text, 5, 0, NULL);
    bk_register_fn(js, lcd, "rgb", lcd_rgb, 3, 0, NULL);
    bk_register_fn(js, lcd, "touch", lcd_touch, 0, 0, NULL);
    bk_set_property(js, lcd, "width", 5, bk_new_number(js, tft.width()));
    bk_set_property(js, lcd, "height", 6, bk_new_number(js, tft.height()));
    bk_set_global(js, "lcd", lcd);
    bk_free_value(js, lcd);
    bk_register_fn(js, 0, "millis", js_millis, 0, 0, NULL);
    bk_register_fn(js, 0, "delay", js_delay, 1, 0, NULL);
}

static void show_error(bk_ctx js, const char *where)
{
    const char *msg = bk_get_error_message(js);
    Serial.printf("%s: %s\n", where, msg);
    tft.fillRect(0, 0, tft.width(), 40, TFT_RED);
    tft.setTextColor(TFT_WHITE);
    tft.setTextSize(1);
    tft.drawString(where, 4, 4);
    tft.drawString(msg, 4, 20);
}

static void engine_task(void *)
{
    bk_esp32_init();
    bk_ctx js = bk_create();
    if (!js) {
        Serial.println("bk_create failed");
        vTaskDelete(NULL);
    }
    install_api(js);
    Serial.printf("boomkat %s, free heap %u\n", bk_version(), ESP.getFreeHeap());

    bk_value r = bk_eval(js, DEMO_JS);
    if (bk_is_exception(r)) {
        show_error(js, "demo script");
        vTaskDelete(NULL);
    }
    bk_free_value(js, r);

    bk_value global = bk_get_global_object(js);
    bk_value frame = bk_get_property(js, global, "frame", 5);
    bk_free_value(js, global);
    for (;;) {
        bk_value t = bk_new_number(js, millis());
        r = bk_call(js, frame, BK_UNDEFINED, &t, 1);
        if (bk_is_exception(r)) {
            show_error(js, "frame()");
            break;
        }
        bk_free_value(js, r);
        vTaskDelay(1);
    }
    bk_free_value(js, frame);
    bk_destroy(js);
    vTaskDelete(NULL);
}

void setup()
{
    Serial.begin(115200);
    tft.init();
    tft.fillScreen(TFT_BLACK);
    xTaskCreate(engine_task, "boomkat", ENGINE_STACK, NULL, 1, NULL);
}

void loop()
{
    delay(1000);
}
