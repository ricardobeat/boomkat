/* ArrayBuffers, external buffers, typed arrays and shared blocks. */
#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int released;
static void *released_data;

static void release(void *data, void *opaque) {
    released++;
    released_data = data;
    assert(opaque == &released);
}

static bk_value eval(bk_ctx ctx, const char *src) {
    bk_value r = bk_eval_ex(ctx, src, strlen(src), "binary.js", BK_EVAL_GLOBAL);
    if (bk_is_exception(r)) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    assert(!bk_is_exception(r));
    return r;
}

static double num(bk_ctx ctx, const char *src) { return bk_to_number(ctx, eval(ctx, src)); }

int main(void) {
    bk_ctx ctx = bk_create();

    /* A runtime-owned buffer written from C and read from JS. */
    void *data = NULL;
    bk_value ab = bk_new_array_buffer(ctx, 8, &data);
    assert(ab && data);
    ((unsigned char *)data)[3] = 7;
    bk_set_global_property(ctx, "ab", 2, ab);
    assert(num(ctx, "new Uint8Array(ab)[3]") == 7);
    assert(num(ctx, "ab.byteLength") == 8);
    void *got; size_t len;
    assert(bk_get_array_buffer(ctx, ab, &got, &len) == BK_OK && got == data && len == 8);
    assert(bk_get_array_buffer(ctx, BK_TRUE, &got, &len) == BK_ERR_TYPE);

    /* Typed arrays over it, with alignment and bounds checks. */
    bk_value f32 = bk_new_typed_array(ctx, BK_FLOAT32, ab, 4, 1);
    assert(f32);
    bk_typed_array_info info;
    assert(bk_get_typed_array(ctx, f32, &info) == BK_OK);
    assert(info.type == BK_FLOAT32 && info.length == 1 && info.byte_offset == 4);
    assert(info.data == (char *)data + 4 && bk_strict_equals(ctx, info.buffer, ab));
    bk_free_value(ctx, info.buffer);
    *(float *)info.data = 2.5f;
    bk_set_global_property(ctx, "f", 1, f32);
    assert(num(ctx, "f[0] + (f instanceof Float32Array ? 1 : 0)") == 3.5);
    assert(bk_new_typed_array(ctx, BK_FLOAT32, ab, 2, 1) == 0 && bk_get_error_code(ctx) == BK_ERR_INVALID);
    assert(bk_new_typed_array(ctx, BK_FLOAT64, ab, 0, 2) == 0 && bk_get_error_code(ctx) == BK_ERR_INVALID);
    assert(bk_new_typed_array(ctx, (bk_element_type)99, ab, 0, 0) == 0 && bk_get_error_code(ctx) == BK_ERR_INVALID);
    assert(bk_get_typed_array(ctx, ab, &info) == BK_ERR_TYPE);
    bk_value u8 = eval(ctx, "new Uint8Array([1, 2, 3]).subarray(1)");
    assert(bk_get_typed_array(ctx, u8, &info) == BK_OK && info.type == BK_UINT8 && info.length == 2);
    assert(((unsigned char *)info.data)[0] == 2);
    bk_free_value(ctx, info.buffer);

    /* Detaching leaves views empty. */
    assert(bk_detach_array_buffer(ctx, ab) == BK_OK);
    assert(bk_get_array_buffer(ctx, ab, &got, &len) == BK_OK && got == NULL && len == 0);
    assert(bk_get_typed_array(ctx, f32, &info) == BK_OK && info.data == NULL && info.length == 0);
    bk_free_value(ctx, info.buffer);
    assert(num(ctx, "ab.detached ? f.length : -1") == 0);
    assert(bk_new_typed_array(ctx, BK_UINT8, ab, 0, 0) == 0 && bk_get_error_code(ctx) == BK_ERR_TYPE);

    /* External memory: shared without copying, released once on detach. */
    double mesh[4] = { 1, 2, 3, 4 };
    bk_value ext = bk_new_external_array_buffer(ctx, mesh, sizeof mesh, release, &released);
    assert(ext);
    bk_value view = bk_new_typed_array(ctx, BK_FLOAT64, ext, 0, 4);
    bk_set_global_property(ctx, "mesh", 4, view);
    assert(num(ctx, "mesh.reduce((a, b) => a + b)") == 10);
    eval(ctx, "mesh[0] = 100");
    assert(mesh[0] == 100);
    assert(bk_detach_array_buffer(ctx, ext) == BK_OK);
    assert(released == 1 && released_data == mesh);
    assert(num(ctx, "mesh.length") == 0);
    assert(bk_detach_array_buffer(ctx, ext) == BK_OK && released == 1);

    /* transfer() copies out and releases the source. */
    bk_value ext2 = bk_new_external_array_buffer(ctx, mesh, sizeof mesh, release, &released);
    bk_set_global_property(ctx, "ext2", 4, ext2);
    assert(num(ctx, "new Float64Array(ext2.transfer())[0]") == 100);
    assert(released == 2);

    /* Collection and teardown release the rest. */
    bk_value ext3 = bk_new_external_array_buffer(ctx, mesh, sizeof mesh, release, &released);
    bk_free_value(ctx, ext3);
    bk_value ext4 = bk_new_external_array_buffer(ctx, mesh, sizeof mesh, release, &released);
    bk_set_global_property(ctx, "kept", 4, ext4);

    /* A failed creation releases at once. */
    assert(bk_new_external_array_buffer(ctx, NULL, 4, release, &released) == 0);
    assert(bk_get_error_code(ctx) == BK_ERR_INVALID);

    /* Shared blocks outlive the runtime that made them. */
    void *block = NULL;
    bk_value sab = bk_new_shared_array_buffer(ctx, 16, &block);
    if (sab == 0) {
        assert(bk_get_error_code(ctx) == BK_ERR_UNSUPPORTED);
    } else {
        bk_set_global_property(ctx, "sab", 3, sab);
        eval(ctx, "Atomics.store(new Int32Array(sab), 1, 42)");
        assert(bk_detach_array_buffer(ctx, sab) == BK_ERR_TYPE);
        bk_shared_block_retain(block);
    }
    int before = released;
    bk_destroy(ctx);
    assert(released == before + 2 && released == 5);
    printf("external releases: %d\n", released);

    if (block) {
        bk_ctx other = bk_create();
        bk_value adopted = bk_adopt_shared_block(other, block);
        bk_shared_block_release(block);
        assert(adopted);
        bk_set_global_property(other, "sab", 3, adopted);
        assert(bk_to_number(other, bk_eval_ex(other, "new Int32Array(sab)[1]", 22, "x.js", BK_EVAL_GLOBAL)) == 42);
        bk_destroy(other);
    }
    puts("binary: PASS");
    return 0;
}
