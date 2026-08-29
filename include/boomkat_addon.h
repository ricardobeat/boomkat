/*
 * boomkat_addon.h — the native add-on ABI.
 *
 * An add-on is a shared library exporting exactly one symbol:
 *
 *     int bk_init_addon(BkAddonCtx *ctx, const BkAddonApi *api);
 *
 * It links against no engine symbols: everything it needs arrives through
 * `api`. That keeps the contract to one struct, and means adding a function to
 * the engine cannot accidentally become part of the ABI.
 *
 * Field order in BkAddonApi is the ABI. Within a major version fields may be
 * appended; reordering or removing one is a breaking change and must bump
 * BK_ADDON_ABI_VERSION.
 *
 * See addons/deflate/deflate_addon.c for a complete example.
 */
#ifndef BOOMKAT_ADDON_H
#define BOOMKAT_ADDON_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BK_ADDON_ABI_VERSION 1u

#define BK_ADDON_OK           0
#define BK_ADDON_ERR_OPEN    (-1)
#define BK_ADDON_ERR_SYMBOL  (-2)
#define BK_ADDON_ERR_VERSION (-3)
#define BK_ADDON_ERR_INIT    (-4)
#define BK_ADDON_ERR_DISABLED (-5)

/* Opaque engine state. Pass it back to api calls; do not inspect it. */
typedef struct BkAddonCtx BkAddonCtx;

/* A handle is a JS value valid for the duration of one call. Anything the
 * add-on keeps must live in a payload and be reported from its gc_mark. */
typedef unsigned long long BkHandle;

/* A method or constructor. `bctx` is opaque; read arguments and write the
 * result through the api calls that take it. */
typedef void (*BkAddonFn)(void *bctx, void *udata);

/* Mark every JS value the payload holds, via api->mark_value(heap, &tval).
 * Omitting a value here is a use-after-free that only shows under memory
 * pressure, so this is the callback to get right. */
typedef void (*BkClassMarkFn)(void *payload, void *heap, void *udata);

/* Free what the payload owns. Runs on collection and on heap teardown. Must
 * not allocate JS objects or resurrect anything. */
typedef void (*BkClassFinalizeFn)(void *payload, void *udata);

typedef struct BkAddonApi {
    unsigned int version;

    /* -- registration -- */
    long   (*class_register)(BkAddonCtx *ctx, const char *name,
                             BkClassFinalizeFn finalizer, BkClassMarkFn gc_mark,
                             void *udata, void *proto);
    void  *(*proto_new)(BkAddonCtx *ctx);
    void  *(*object_new)(BkAddonCtx *ctx);
    int    (*fn_new)(BkAddonCtx *ctx, const char *name, BkAddonFn cfn,
                     void *udata, int arity, int constructable,
                     BkHandle *out_handle);
    int    (*object_set)(BkAddonCtx *ctx, void *obj, const char *name,
                         BkHandle value);
    /* Same, when the target is itself a handle (e.g. a constructor object
     * just returned by fn_new). */
    int    (*object_set_by_handle)(BkAddonCtx *ctx, BkHandle target,
                                   const char *name, BkHandle value);
    int    (*object_set_getter)(BkAddonCtx *ctx, void *obj, const char *name,
                                BkAddonFn cfn, void *udata);
    int    (*global_set)(BkAddonCtx *ctx, const char *name, BkHandle value);
    BkHandle (*handle_for_object)(BkAddonCtx *ctx, void *obj);

    /* -- instances -- */
    void  *(*instance_new)(BkAddonCtx *ctx, long class_id, void *payload);
    /* The brand check: NULL unless `obj` is an instance of `class_id`. Every
     * method should start here, so a stolen method throws instead of
     * reinterpreting a foreign object's internals. */
    void  *(*instance_payload)(void *obj, long class_id);

    /* -- calling convention -- */
    unsigned int (*arg_count)(void *bctx);
    /* Bytes of string argument `i`, or NULL. Not NUL-terminated; use out_len.
     * Valid only for the duration of the call. */
    const char  *(*arg_string)(void *bctx, unsigned int i, size_t *out_len);
    double       (*arg_number)(void *bctx, unsigned int i);
    BkHandle     (*arg_handle)(void *bctx, unsigned int i);
    BkHandle     (*this_handle)(void *bctx);
    void         (*return_number)(void *bctx, double v);
    void         (*return_string)(void *bctx, const char *bytes, size_t len);
    void         (*return_object)(void *bctx, void *obj);
    void         (*return_handle)(void *bctx, BkHandle h);
    void         (*return_undefined)(void *bctx);
    void         (*throw_type_error)(void *bctx, const char *msg);
    void         (*throw_range_error)(void *bctx, const char *msg);

    /* -- values held across calls -- */
    /* Convert between a handle and the raw value slot stored in a payload.
     * `tval` points at BK_TVAL_SIZE bytes the add-on owns. */
    void     (*handle_store)(void *bctx, BkHandle h, void *tval);
    BkHandle (*handle_load)(void *bctx, void *tval);
    /* The object behind a handle, or NULL. Pair with instance_payload for a
     * brand check on `this`. */
    void    *(*handle_object)(void *bctx, BkHandle h);
    void     (*mark_value)(void *heap, void *tval);

    /* -- memory -- */
    void *(*mem_alloc)(BkAddonCtx *ctx, size_t n);
    void *(*mem_realloc)(BkAddonCtx *ctx, void *p, size_t n);
    void  (*mem_free)(BkAddonCtx *ctx, void *p);
} BkAddonApi;

/* Size of the opaque value slot an add-on embeds in its payload to retain a
 * JS value. Sized for the largest TVal representation the engine builds with
 * (16 bytes in the NONANBOX build, 8 when NaN-boxed), so one add-on binary
 * works against either. Treat the contents as opaque; only handle_store,
 * handle_load and mark_value may touch them. */
#define BK_TVAL_SIZE 16

typedef int (*BkAddonInitFn)(BkAddonCtx *ctx, const BkAddonApi *api);

#ifdef __cplusplus
}
#endif

#endif /* BOOMKAT_ADDON_H */
