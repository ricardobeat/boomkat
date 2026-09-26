/*
 * native_stack.c — the bounds of the calling thread's native stack.
 *
 * The compiler is recursive descent, so deeply nested source recurses once per
 * level and would run off the end of the stack. boomkat_stack_low() lets it
 * compare its own stack pointer against the real limit instead of a fixed
 * depth, which is right on an 8 MB main thread and on a small embedded task
 * alike. The thread APIs take platform-specific struct types, so this lives
 * in C rather than as C3 externs.
 */
#if defined(__APPLE__)
#include <pthread.h>
#elif defined(__linux__)
#define _GNU_SOURCE
#include <pthread.h>
#elif defined(_WIN32)
#include <windows.h>
#endif

#include <stdint.h>

/* Lowest address of the calling thread's stack (stacks grow down on every
 * supported target), or 0 when the platform gives no way to ask. */
uintptr_t boomkat_stack_low(void)
{
#if defined(__APPLE__)
    pthread_t self = pthread_self();
    return (uintptr_t)pthread_get_stackaddr_np(self) - pthread_get_stacksize_np(self);
#elif defined(__linux__)
    pthread_attr_t attr;
    void *addr = 0;
    size_t size = 0;
    if (pthread_getattr_np(pthread_self(), &attr) != 0) return 0;
    int rc = pthread_attr_getstack(&attr, &addr, &size);
    pthread_attr_destroy(&attr);
    return rc == 0 ? (uintptr_t)addr : 0;
#elif defined(_WIN32)
    ULONG_PTR low = 0, high = 0;
    GetCurrentThreadStackLimits(&low, &high);
    return (uintptr_t)low;
#else
    return 0;
#endif
}
