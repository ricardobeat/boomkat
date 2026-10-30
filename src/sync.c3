// Mutex, condition variable, and thread for the agent machinery.
//
// C3's stdlib sizes the Linux pthread types for x86-64 glibc on every Linux
// architecture. On aarch64, pthread_mutex_t, pthread_mutexattr_t,
// pthread_condattr_t and pthread_attr_t are all larger, so the stdlib's init
// and create calls overrun their storage, including attribute locals on their
// own stack frames. On Linux these wrappers call pthreads directly with
// storage large enough for any glibc or musl target. Elsewhere they wrap the
// stdlib types.
module boomkat::sync;

// Bytes reserved for any pthread object. glibc aarch64's largest is 64.
const usz PTHREAD_STORAGE = 64;

module boomkat::sync @feat(LINUX);
import libc;

struct Lock {
    ulong[PTHREAD_STORAGE / 8] raw;
}

struct Cond {
    ulong[PTHREAD_STORAGE / 8] raw;
}

struct OsThread {
    ulong handle;   // pthread_t is an unsigned long on Linux
}

// Matches libc's timespec as C3 declares it, so 32-bit targets agree with std.
struct TimeSpecNs {
    Time_t sec;
    CLong nsec;
}

const CInt CLOCK_MONOTONIC = 1;

extern fn CInt sys_mutex_init(void* m, void* attr) @cname("pthread_mutex_init");
extern fn CInt sys_mutex_destroy(void* m) @cname("pthread_mutex_destroy");
extern fn CInt sys_mutex_lock(void* m) @cname("pthread_mutex_lock");
extern fn CInt sys_mutex_unlock(void* m) @cname("pthread_mutex_unlock");
extern fn CInt sys_condattr_init(void* a) @cname("pthread_condattr_init");
extern fn CInt sys_condattr_setclock(void* a, CInt clock) @cname("pthread_condattr_setclock");
extern fn CInt sys_condattr_destroy(void* a) @cname("pthread_condattr_destroy");
extern fn CInt sys_cond_init(void* c, void* attr) @cname("pthread_cond_init");
extern fn CInt sys_cond_destroy(void* c) @cname("pthread_cond_destroy");
extern fn CInt sys_cond_signal(void* c) @cname("pthread_cond_signal");
extern fn CInt sys_cond_broadcast(void* c) @cname("pthread_cond_broadcast");
extern fn CInt sys_cond_wait(void* c, void* m) @cname("pthread_cond_wait");
extern fn CInt sys_cond_timedwait(void* c, void* m, TimeSpecNs* abs) @cname("pthread_cond_timedwait");
extern fn CInt sys_clock_gettime(CInt clock, TimeSpecNs* ts) @cname("clock_gettime");
extern fn CInt sys_attr_init(void* a) @cname("pthread_attr_init");
extern fn CInt sys_attr_setstacksize(void* a, usz size) @cname("pthread_attr_setstacksize");
extern fn CInt sys_attr_destroy(void* a) @cname("pthread_attr_destroy");
extern fn CInt sys_thread_create(ulong* t, void* attr, ThreadEntry entry, void* arg) @cname("pthread_create");
extern fn CInt sys_thread_join(ulong t, void** result) @cname("pthread_join");

alias ThreadEntry = fn void*(void*);

fn void Lock.init(&self) {
    if (sys_mutex_init(&self.raw, null) != 0) abort("pthread_mutex_init failed");
}
fn void Lock.destroy(&self) => (void)sys_mutex_destroy(&self.raw);
fn void Lock.lock(&self) {
    if (sys_mutex_lock(&self.raw) != 0) abort("pthread_mutex_lock failed");
}
fn void Lock.unlock(&self) => (void)sys_mutex_unlock(&self.raw);

// Timed waits measure against CLOCK_MONOTONIC, so a wall-clock change cannot
// stretch or cut short an Atomics.wait timeout.
fn void Cond.init(&self) {
    ulong[PTHREAD_STORAGE / 8] attr;
    if (sys_condattr_init(&attr) != 0) abort("pthread_condattr_init failed");
    (void)sys_condattr_setclock(&attr, CLOCK_MONOTONIC);
    CInt rc = sys_cond_init(&self.raw, &attr);
    (void)sys_condattr_destroy(&attr);
    if (rc != 0) abort("pthread_cond_init failed");
}
fn void Cond.destroy(&self) => (void)sys_cond_destroy(&self.raw);
fn void Cond.signal(&self) => (void)sys_cond_signal(&self.raw);
fn void Cond.broadcast(&self) => (void)sys_cond_broadcast(&self.raw);
fn void Cond.wait(&self, Lock* lock) => (void)sys_cond_wait(&self.raw, &lock.raw);

// Waits at most `ns` nanoseconds. Spurious and timed-out returns look alike;
// callers re-check their condition.
fn void Cond.wait_ns(&self, Lock* lock, ulong ns) {
    TimeSpecNs ts;
    (void)sys_clock_gettime(CLOCK_MONOTONIC, &ts);
    ulong nsec = (ulong)ts.nsec + ns % 1_000_000_000;
    ts.sec += (Time_t)(ns / 1_000_000_000 + nsec / 1_000_000_000);
    ts.nsec = (CLong)(nsec % 1_000_000_000);
    (void)sys_cond_timedwait(&self.raw, &lock.raw, &ts);
}

struct ThreadStart @private {
    ThreadFn fn_ptr;
    void*    arg;
}

alias ThreadFn = fn int(void*);

fn void* thread_trampoline(void* p) @private {
    ThreadStart start = *(ThreadStart*)p;
    libc::free(p);
    start.fn_ptr(start.arg);
    return null;
}

// Starts `fn_ptr(arg)` on a new thread with a `stack_size`-byte stack.
// False when the thread could not be created.
fn bool OsThread.start(&self, ThreadFn fn_ptr, void* arg, usz stack_size) {
    ThreadStart* start = (ThreadStart*)libc::malloc(ThreadStart::size);
    if (start == null) return false;
    start.fn_ptr = fn_ptr;
    start.arg = arg;
    ulong[PTHREAD_STORAGE / 8] attr;
    if (sys_attr_init(&attr) != 0) {
        libc::free(start);
        return false;
    }
    defer (void)sys_attr_destroy(&attr);
    if (stack_size > 0 && sys_attr_setstacksize(&attr, stack_size) != 0) {
        libc::free(start);
        return false;
    }
    if (sys_thread_create(&self.handle, &attr, &thread_trampoline, start) != 0) {
        libc::free(start);
        return false;
    }
    return true;
}

fn void OsThread.join(&self) => (void)sys_thread_join(self.handle, null);

module boomkat::sync @feat(!LINUX);
import std::thread;
import std::time;

struct Lock {
    Mutex m;
}

struct Cond {
    ConditionVariable cv;
}

struct OsThread {
    Thread t;
}

alias ThreadFn = fn int(void*);

fn void Lock.init(&self) => self.m.init()!!;
fn void Lock.destroy(&self) => self.m.destroy();
fn void Lock.lock(&self) => self.m.lock();
fn void Lock.unlock(&self) => self.m.unlock();

fn void Cond.init(&self) => self.cv.init()!!;
fn void Cond.destroy(&self) => self.cv.destroy();
fn void Cond.signal(&self) => self.cv.signal();
fn void Cond.broadcast(&self) => self.cv.broadcast();
fn void Cond.wait(&self, Lock* lock) => self.cv.wait(&lock.m);
fn void Cond.wait_ns(&self, Lock* lock, ulong ns) {
    if (catch self.cv.wait_timeout(&lock.m, time::us((long)((ns + 999) / 1000)))) {}
}

fn bool OsThread.start(&self, ThreadFn fn_ptr, void* arg, usz stack_size) {
    if (catch self.t.create(fn_ptr, arg, { .stack_size = (sz)stack_size })) return false;
    return true;
}

fn void OsThread.join(&self) {
    if (catch self.t.join()) {}
}
