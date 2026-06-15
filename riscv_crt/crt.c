/* Minimal RISC-V libc stubs for TinyDuck custom allocator */

#include <stddef.h>
#include <stdint.h>

/* Simple bump allocator using sbrk */
static char *heap_start = 0;
static char *heap_ptr = 0;
static char *heap_end = 0;

extern void *sbrk(ptrdiff_t increment);

#define HEAP_INITIAL_SIZE (512 * 1024)

void *malloc(size_t size) {
    if (heap_start == 0) {
        heap_start = (char *)sbrk(0);
        heap_ptr = heap_start;
        heap_end = heap_start + HEAP_INITIAL_SIZE;
        sbrk(HEAP_INITIAL_SIZE);
    }
    /* Align to 16 bytes */
    size = (size + 15) & ~15;
    if (heap_ptr + size > heap_end) {
        size_t needed = heap_ptr + size - heap_end;
        needed = (needed + 4095) & ~4095;
        if (sbrk(needed) == (void*)-1) return 0;
        heap_end += needed;
    }
    void *ptr = heap_ptr;
    heap_ptr += size;
    return ptr;
}

void free(void *ptr) {
    (void)ptr;
}

void *realloc(void *ptr, size_t size) {
    if (!ptr) return malloc(size);
    void *new_ptr = malloc(size);
    if (new_ptr) {
        char *src = (char *)ptr;
        char *dst = (char *)new_ptr;
        for (size_t i = 0; i < size; i++) dst[i] = src[i];
    }
    return new_ptr;
}

void *calloc(size_t nmemb, size_t size) {
    size_t total = nmemb * size;
    void *ptr = malloc(total);
    if (ptr) {
        char *p = (char *)ptr;
        for (size_t i = 0; i < total; i++) p[i] = 0;
    }
    return ptr;
}
