#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

struct bk_cp_op { uint32_t kind, dst, left, right; double constant; };

#if defined(__APPLE__) && defined(__aarch64__)
#include <sys/mman.h>
#include <pthread.h>
#include <libkern/OSCacheControl.h>

__asm__(".text\n.p2align 2\n"
        "_bk_cp_load:\n ldr d0, [x0]\n"
        "_bk_cp_add:\n fadd d0, d0, d0\n"
        "_bk_cp_sub:\n fsub d0, d0, d0\n"
        "_bk_cp_mul:\n fmul d0, d0, d0\n"
        "_bk_cp_div:\n fdiv d0, d0, d0\n"
        "_bk_cp_constant:\n movz x9, #0\n movk x9, #0, lsl #16\n"
        " movk x9, #0, lsl #32\n movk x9, #0, lsl #48\n fmov d0, x9\n"
        "_bk_cp_store:\n str d0, [x1]\n"
        "_bk_cp_move:\n fmov d0, d0\n"
        "_bk_cp_repeat:\n subs w2, w2, #1\n b.ne .\n"
        "_bk_cp_mask:\n fcvtzs x9, d0\n movz w10, #0\n and w9, w9, w10\n scvtf d0, w9\n"
        "_bk_cp_select:\n fcmp d0, #0.0\n fcsel d0, d0, d0, ne\n fcsel d0, d0, d0, vs\n"
        "_bk_cp_stream:\n ldr x9, [x3]\n ldr d0, [x9, x4]\n"
        "_bk_cp_boolean:\n fmov x9, d0\n movz x10, #1\n movk x10, #0xfff5, lsl #48\n cmp x9, x10\n fcsel d0, d0, d0, eq\n"
        "_bk_cp_return:\n ret\n");
extern const uint32_t bk_cp_load[], bk_cp_add[], bk_cp_sub[], bk_cp_mul[],
                      bk_cp_div[], bk_cp_constant[], bk_cp_store[], bk_cp_return[], bk_cp_move[], bk_cp_repeat[], bk_cp_mask[], bk_cp_select[], bk_cp_stream[], bk_cp_boolean[];

static unsigned char *arena;
static size_t used, live;
static pthread_mutex_t arena_lock = PTHREAD_MUTEX_INITIALIZER;
static const size_t arena_size = 1024 * 1024;

/* d8-d15 belong to the caller under AAPCS64. */
static unsigned fpreg(unsigned value) { return value < 8 ? value : value + 8; }

void *bk_copy_patch_compile(const struct bk_cp_op *ops, uint32_t count)
{
    uint32_t words[512];
    size_t length = 0, loop_start = 0;
    for (uint32_t i = 0; i < count; i++) {
        const struct bk_cp_op *op = ops + i;
        if (op->dst >= 24 || length + 5 >= 512) return NULL;
        if (op->kind == 1 || op->kind == 7) {
            if (op->left >= 64) return NULL;
            memcpy(words + length, op->kind == 1 ? bk_cp_load : bk_cp_store, 4);
            words[length++] |= fpreg(op->dst) | (op->left << 10);
        } else if (op->kind >= 2 && op->kind <= 5) {
            if (op->left >= 24 || op->right >= 24) return NULL;
            const uint32_t *stencil = op->kind == 2 ? bk_cp_add :
                op->kind == 3 ? bk_cp_sub : op->kind == 4 ? bk_cp_mul : bk_cp_div;
            memcpy(words + length, stencil, 4);
            words[length++] |= fpreg(op->dst)
                | (fpreg(op->left) << 5)
                | (fpreg(op->right) << 16);
        } else if (op->kind == 6) {
            uint64_t bits;
            memcpy(&bits, &op->constant, 8);
            memcpy(words + length, bk_cp_constant, 20);
            for (unsigned j = 0; j < 4; j++)
                words[length + j] |= ((bits >> (16 * j)) & 0xffff) << 5;
            words[length + 4] |= fpreg(op->dst);
            length += 5;
        } else if (op->kind == 8) {
            if (op->left >= 24) return NULL;
            memcpy(words + length, bk_cp_move, 4);
            words[length++] |= fpreg(op->dst) | (fpreg(op->left) << 5);
        } else if (op->kind == 9) {
            words[length++] = 0xd2800004; /* mov x4, #0 */
            loop_start = length;
        } else if (op->kind == 10) {
            words[length++] = 0x91002084; /* add x4, x4, #8 */
            memcpy(words + length, bk_cp_repeat, 8);
            int32_t offset = (int32_t)loop_start - (int32_t)(length + 1);
            words[length + 1] |= ((uint32_t)offset & 0x7ffff) << 5;
            length += 2;
        } else if (op->kind == 11) {
            if (op->left >= 24 || op->right > 255) return NULL;
            memcpy(words + length, bk_cp_mask, 16);
            words[length] |= fpreg(op->left) << 5;
            words[length + 1] |= op->right << 5;
            words[length + 3] |= fpreg(op->dst);
            length += 4;
        } else if (op->kind == 12) {
            unsigned condition = (unsigned)op->constant;
            if (op->left >= 24 || op->right >= 24 || condition >= 24) return NULL;
            memcpy(words + length, bk_cp_select, 12);
            words[length] |= fpreg(condition) << 5;
            words[length + 1] |= fpreg(op->dst) | (fpreg(op->left) << 5) | (fpreg(op->right) << 16);
            words[length + 2] |= fpreg(op->dst) | (fpreg(op->right) << 5) | (fpreg(op->dst) << 16);
            length += 3;
        } else if (op->kind == 13 || op->kind == 15) {
            if (op->left >= 8) return NULL;
            memcpy(words + length, bk_cp_stream, 8);
            words[length] |= op->left << 10;
            if (op->kind == 15) words[length + 1] = bk_cp_load[0] | (9 << 5);
            words[length + 1] |= fpreg(op->dst);
            length += 2;
        } else if (op->kind == 14) {
            unsigned condition = (unsigned)op->constant;
            if (condition >= 24 || op->left >= 24 || op->right >= 24) return NULL;
            memcpy(words + length, bk_cp_boolean, 20);
            words[length] |= fpreg(condition) << 5;
            words[length + 4] |= fpreg(op->dst) | (fpreg(op->left) << 5) | (fpreg(op->right) << 16);
            length += 5;
        } else return NULL;
    }
    memcpy(words + length++, bk_cp_return, 4);
    size_t bytes = length * 4;
    pthread_mutex_lock(&arena_lock);
    if (!arena) {
        void *mapping = mmap(NULL, arena_size, PROT_READ | PROT_WRITE | PROT_EXEC,
                             MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
        if (mapping == MAP_FAILED) { pthread_mutex_unlock(&arena_lock); return NULL; }
        arena = mapping;
    }
    if (used + bytes > arena_size) { pthread_mutex_unlock(&arena_lock); return NULL; }
    unsigned char *entry = arena + used;
    used += (bytes + 15) & ~(size_t)15;
    pthread_jit_write_protect_np(0);
    memcpy(entry, words, bytes);
    pthread_jit_write_protect_np(1);
    sys_icache_invalidate(entry, bytes);
    live++;
    const char *dump = getenv("BOOMKAT_COPY_PATCH_DUMP");
    if (dump) {
        FILE *file = fopen(dump, "a");
        if (file) {
            fprintf(file, "code %zu bytes\n", bytes);
            for (size_t i = 0; i < length; i++) fprintf(file, "%08x\n", words[i]);
            fclose(file);
        }
    }
    pthread_mutex_unlock(&arena_lock);
    return entry;
}

void bk_copy_patch_release(void *entry)
{
    pthread_mutex_lock(&arena_lock);
    if (entry && live && --live == 0) {
        munmap(arena, arena_size);
        arena = NULL;
        used = 0;
    }
    pthread_mutex_unlock(&arena_lock);
}
#else
void *bk_copy_patch_compile(const struct bk_cp_op *ops, uint32_t count)
{ (void)ops; (void)count; return NULL; }
void bk_copy_patch_release(void *entry) { (void)entry; }
#endif
