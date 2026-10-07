/*
 * sysmem.c — process and machine memory sizes for the heap's memory limit.
 *
 * The limit compares the process's resident set against a byte budget after
 * each GC cycle. Resident size counts every allocation the process holds, the
 * engine's or not, and freed memory the allocator keeps, so the check is a
 * coarse backstop, not an exact accounting. Both queries return 0 where the
 * platform gives no way to ask, which leaves the limit off.
 */
#if defined(__APPLE__)
#include <mach/mach.h>
#include <sys/sysctl.h>
#elif defined(__linux__)
#include <stdio.h>
#include <unistd.h>
#elif defined(_WIN32)
#include <windows.h>
#include <psapi.h>
#endif

#include <stdint.h>

/* Resident memory of this process, in bytes. */
uint64_t boomkat_rss_bytes(void)
{
#if defined(__APPLE__)
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return (uint64_t)info.resident_size;
#elif defined(__linux__)
    FILE *f = fopen("/proc/self/statm", "r");
    if (!f) return 0;
    unsigned long size = 0, resident = 0;
    int n = fscanf(f, "%lu %lu", &size, &resident);
    fclose(f);
    if (n != 2) return 0;
    return (uint64_t)resident * (uint64_t)sysconf(_SC_PAGESIZE);
#elif defined(_WIN32)
    PROCESS_MEMORY_COUNTERS pmc;
    if (!K32GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof(pmc))) return 0;
    return (uint64_t)pmc.WorkingSetSize;
#else
    return 0;
#endif
}

/* Physical memory installed in the machine, in bytes. */
uint64_t boomkat_total_memory(void)
{
#if defined(__APPLE__)
    uint64_t mem = 0;
    size_t len = sizeof(mem);
    if (sysctlbyname("hw.memsize", &mem, &len, NULL, 0) != 0) return 0;
    return mem;
#elif defined(__linux__)
    long pages = sysconf(_SC_PHYS_PAGES);
    long page = sysconf(_SC_PAGESIZE);
    if (pages <= 0 || page <= 0) return 0;
    return (uint64_t)pages * (uint64_t)page;
#elif defined(_WIN32)
    MEMORYSTATUSEX st;
    st.dwLength = sizeof(st);
    if (!GlobalMemoryStatusEx(&st)) return 0;
    return (uint64_t)st.ullTotalPhys;
#else
    return 0;
#endif
}
