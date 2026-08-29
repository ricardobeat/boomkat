/*
 * deflate_addon.c — a native add-on, compiled entirely outside the engine.
 *
 * Build:
 *     cc -shared -fPIC -I../../include -o deflate.dylib deflate_addon.c -lz
 *
 * Load:
 *     loadAddon("addons/deflate/deflate.dylib");
 *
 * This file links against no engine symbol: everything arrives through the
 * BkAddonApi vtable. It is here to prove the ABI carries a type with real
 * state, not because deflate is interesting.
 *
 * What it exercises:
 *   - a class registered at runtime, with a finalizer and a gc_mark
 *   - a payload the engine never interprets
 *   - a JS value retained inside that payload, kept alive only because
 *     mark_deflater reports it (see `tag` below)
 *   - a brand check on every method, so a stolen method throws
 *
 * JS surface:
 *     const d = new Deflater(tag?);
 *     d.push(str) -> total bytes accumulated
 *     d.bytesIn   -> accessor
 *     d.tag       -> the retained value
 *     Deflate.compress(str)  -> compressed byte length
 *     Deflate.roundtrip(str) -> str
 */
#include <string.h>
#include <zlib.h>

#include "boomkat_addon.h"

static const BkAddonApi *g_api;
static BkAddonCtx *g_ctx;
static long g_deflater_class = -1;

/* Payload. Opaque to the engine; this file owns the layout and the memory. */
typedef struct {
    char *buf;
    size_t len;
    size_t cap;
    /* A retained JS value. Stored as raw bytes because its representation is
     * the engine's business, not ours -- see BK_TVAL_SIZE. */
    unsigned char tag[BK_TVAL_SIZE];
    int has_tag;
} DeflaterState;

/* ------------------------------------------------------------------ */
/* Class callbacks                                                     */
/* ------------------------------------------------------------------ */

static void finalize_deflater(void *payload, void *udata)
{
    DeflaterState *st = (DeflaterState *)payload;
    (void)udata;
    if (!st) return;
    if (st->buf) g_api->mem_free(g_ctx, st->buf);
    g_api->mem_free(g_ctx, st);
}

/* The load-bearing callback. Without it, a value reachable only through this
 * payload is freed by the next collection and `d.tag` reads freed memory. */
static void mark_deflater(void *payload, void *heap, void *udata)
{
    DeflaterState *st = (DeflaterState *)payload;
    (void)udata;
    if (!st || !st->has_tag) return;
    g_api->mark_value(heap, st->tag);
}

/* ------------------------------------------------------------------ */
/* Methods                                                             */
/* ------------------------------------------------------------------ */

/* Brand check shared by every instance method: a method applied to a foreign
 * object must throw rather than reinterpret that object's internals. */
static DeflaterState *self_of(void *bctx)
{
    void *self = g_api->handle_object(bctx, g_api->this_handle(bctx));
    return (DeflaterState *)g_api->instance_payload(self, g_deflater_class);
}

static void js_deflater_ctor(void *bctx, void *udata)
{
    (void)udata;
    DeflaterState *st = (DeflaterState *)g_api->mem_alloc(g_ctx, sizeof *st);
    if (!st) { g_api->throw_range_error(bctx, "out of memory"); return; }
    memset(st, 0, sizeof *st);

    if (g_api->arg_count(bctx) >= 1) {
        g_api->handle_store(bctx, g_api->arg_handle(bctx, 0), st->tag);
        st->has_tag = 1;
    }

    void *obj = g_api->instance_new(g_ctx, g_deflater_class, st);
    if (!obj) {
        g_api->mem_free(g_ctx, st);
        g_api->throw_range_error(bctx, "out of memory");
        return;
    }
    g_api->return_object(bctx, obj);
}

static void js_deflater_push(void *bctx, void *udata)
{
    (void)udata;
    DeflaterState *st = self_of(bctx);
    if (!st) { g_api->throw_type_error(bctx, "not a Deflater"); return; }

    size_t n = 0;
    const char *p = g_api->arg_string(bctx, 0, &n);
    if (p && n) {
        size_t need = st->len + n;
        if (need > st->cap) {
            size_t cap = st->cap ? st->cap : 64;
            while (cap < need) cap *= 2;
            char *grown = (char *)g_api->mem_realloc(g_ctx, st->buf, cap);
            if (!grown) { g_api->throw_range_error(bctx, "out of memory"); return; }
            st->buf = grown;
            st->cap = cap;
        }
        memcpy(st->buf + st->len, p, n);
        st->len = need;
    }
    g_api->return_number(bctx, (double)st->len);
}

static void js_deflater_bytes_in(void *bctx, void *udata)
{
    (void)udata;
    DeflaterState *st = self_of(bctx);
    if (!st) { g_api->throw_type_error(bctx, "not a Deflater"); return; }
    g_api->return_number(bctx, (double)st->len);
}

static void js_deflater_tag(void *bctx, void *udata)
{
    (void)udata;
    DeflaterState *st = self_of(bctx);
    if (!st) { g_api->throw_type_error(bctx, "not a Deflater"); return; }
    if (!st->has_tag) { g_api->return_undefined(bctx); return; }
    g_api->return_handle(bctx, g_api->handle_load(bctx, st->tag));
}

static void js_compress(void *bctx, void *udata)
{
    (void)udata;
    size_t n = 0;
    const char *p = g_api->arg_string(bctx, 0, &n);
    if (!p) { g_api->return_number(bctx, 0); return; }

    uLongf out_len = compressBound((uLong)n);
    unsigned char *out = (unsigned char *)g_api->mem_alloc(g_ctx, out_len);
    if (!out) { g_api->throw_range_error(bctx, "out of memory"); return; }
    int rc = compress2(out, &out_len, (const Bytef *)p, (uLong)n, 9);
    g_api->return_number(bctx, rc == Z_OK ? (double)out_len : 0);
    g_api->mem_free(g_ctx, out);
}

static void js_roundtrip(void *bctx, void *udata)
{
    (void)udata;
    size_t n = 0;
    const char *p = g_api->arg_string(bctx, 0, &n);
    if (!p) { g_api->return_undefined(bctx); return; }

    uLongf packed_len = compressBound((uLong)n);
    unsigned char *packed = (unsigned char *)g_api->mem_alloc(g_ctx, packed_len);
    if (!packed) { g_api->throw_range_error(bctx, "out of memory"); return; }

    if (compress2(packed, &packed_len, (const Bytef *)p, (uLong)n, 9) != Z_OK) {
        g_api->mem_free(g_ctx, packed);
        g_api->return_undefined(bctx);
        return;
    }

    uLongf back_len = (uLongf)n;
    char *back = (char *)g_api->mem_alloc(g_ctx, back_len ? back_len : 1);
    if (!back) {
        g_api->mem_free(g_ctx, packed);
        g_api->throw_range_error(bctx, "out of memory");
        return;
    }
    int rc = uncompress((Bytef *)back, &back_len, packed, packed_len);
    if (rc == Z_OK) g_api->return_string(bctx, back, back_len);
    else            g_api->return_undefined(bctx);

    g_api->mem_free(g_ctx, packed);
    g_api->mem_free(g_ctx, back);
}

/* ------------------------------------------------------------------ */
/* Entry point                                                         */
/* ------------------------------------------------------------------ */

int bk_init_addon(BkAddonCtx *ctx, const BkAddonApi *api)
{
    if (!api || api->version != BK_ADDON_ABI_VERSION) return BK_ADDON_ERR_VERSION;
    g_api = api;
    g_ctx = ctx;

    /* Deflater.prototype, then the class that points at it. */
    void *proto = api->proto_new(ctx);
    if (!proto) return BK_ADDON_ERR_INIT;

    g_deflater_class = api->class_register(ctx, "Deflater",
                                           finalize_deflater, mark_deflater,
                                           NULL, proto);
    if (g_deflater_class < 0) return BK_ADDON_ERR_INIT;

    BkHandle h;
    if (api->fn_new(ctx, "push", js_deflater_push, NULL, 1, 0, &h) != BK_ADDON_OK)
        return BK_ADDON_ERR_INIT;
    if (api->object_set(ctx, proto, "push", h) != BK_ADDON_OK)
        return BK_ADDON_ERR_INIT;

    if (api->object_set_getter(ctx, proto, "bytesIn", js_deflater_bytes_in, NULL) != BK_ADDON_OK)
        return BK_ADDON_ERR_INIT;
    if (api->object_set_getter(ctx, proto, "tag", js_deflater_tag, NULL) != BK_ADDON_OK)
        return BK_ADDON_ERR_INIT;

    /* The constructor, with .prototype wired both ways. */
    BkHandle ctor;
    if (api->fn_new(ctx, "Deflater", js_deflater_ctor, NULL, 1, 1, &ctor) != BK_ADDON_OK)
        return BK_ADDON_ERR_INIT;
    if (api->object_set(ctx, proto, "constructor", ctor) != BK_ADDON_OK)
        return BK_ADDON_ERR_INIT;
    /* .prototype on the constructor, so `new Deflater` gets the right proto. */
    if (api->object_set_by_handle(ctx, ctor, "prototype",
                                  api->handle_for_object(ctx, proto)) != BK_ADDON_OK)
        return BK_ADDON_ERR_INIT;
    if (api->global_set(ctx, "Deflater", ctor) != BK_ADDON_OK)
        return BK_ADDON_ERR_INIT;

    /* The Deflate namespace. */
    void *ns = api->object_new(ctx);
    if (!ns) return BK_ADDON_ERR_INIT;
    if (api->fn_new(ctx, "compress", js_compress, NULL, 1, 0, &h) != BK_ADDON_OK)
        return BK_ADDON_ERR_INIT;
    if (api->object_set(ctx, ns, "compress", h) != BK_ADDON_OK)
        return BK_ADDON_ERR_INIT;
    if (api->fn_new(ctx, "roundtrip", js_roundtrip, NULL, 1, 0, &h) != BK_ADDON_OK)
        return BK_ADDON_ERR_INIT;
    if (api->object_set(ctx, ns, "roundtrip", h) != BK_ADDON_OK)
        return BK_ADDON_ERR_INIT;

    BkHandle nsh = api->handle_for_object(ctx, ns);
    if (api->global_set(ctx, "Deflate", nsh) != BK_ADDON_OK)
        return BK_ADDON_ERR_INIT;

    return BK_ADDON_OK;
}
