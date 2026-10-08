/* Test-only portability layer for the C oracles. Never linked into LAMP.
   LAMP's assembly uses the Microsoft x64 calling convention on every platform,
   so prototypes for assembly functions carry LAMP_ABI. On Linux this header
   also supplies the few Win32 memory/timing calls the oracles use, built on
   POSIX, and maps the wide-character entry point and paths to UTF-8. */
#ifndef LAMP_TEST_H
#define LAMP_TEST_H
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <psapi.h>
#define LAMP_ABI
typedef wchar_t lamp_char;
#define LT(text) L##text
#define lamp_main wmain
#define lamp_fopen _wfopen
#define lamp_atoi _wtoi
/* Microsoft wide printf: %s formats a wide string. */
#define lamp_snprintf _snwprintf
#define lamp_strlen wcslen
#define lamp_strcmp wcscmp
#define lamp_strtou64 _wcstoui64
#include <winioctl.h>
/* Sparse fixture files: create with a size, write at offsets, then report
   the allocated bytes after closing. */
typedef HANDLE lamp_file;
static inline int lamp_sparse_create(const lamp_char *path, uint64_t size, lamp_file *file) {
    DWORD returned; LARGE_INTEGER end; end.QuadPart = (LONGLONG)size;
    HANDLE h = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    *file = h;
    return DeviceIoControl(h, FSCTL_SET_SPARSE, NULL, 0, NULL, 0, &returned, NULL) &&
        SetFilePointerEx(h, end, NULL, FILE_BEGIN) && SetEndOfFile(h);
}
static inline int lamp_sparse_put(lamp_file h, uint64_t at, const void *p, DWORD n) {
    LARGE_INTEGER pos; DWORD done; pos.QuadPart = (LONGLONG)at;
    return SetFilePointerEx(h, pos, NULL, FILE_BEGIN) && WriteFile(h, p, n, &done, NULL) && done == n;
}
static inline int lamp_sparse_close(lamp_file h, const lamp_char *path, uint64_t *allocated) {
    DWORD high = 0;
    if (!FlushFileBuffers(h)) return 0;
    CloseHandle(h);
    *allocated = GetCompressedFileSizeW(path, &high);
    *allocated |= (uint64_t)high << 32;
    return 1;
}
#else
#include <errno.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <malloc/malloc.h>
#endif
#if defined(__APPLE__) && defined(__aarch64__)
/* The Mac library exports Apple ABI bridges to the shared decoder machine. */
#define LAMP_ABI
#else
#define LAMP_ABI __attribute__((ms_abi))
#endif
typedef char lamp_char;
#define LT(text) text
#define lamp_main main
#define lamp_fopen fopen
#define lamp_atoi atoi
#define lamp_snprintf snprintf
#define lamp_strlen strlen
#define lamp_strcmp strcmp
#define lamp_strtou64 strtoull

typedef int BOOL;
typedef unsigned long DWORD;
typedef size_t SIZE_T;
typedef void *HANDLE;
typedef int64_t LONGLONG;
typedef union { struct { DWORD LowPart; int32_t HighPart; } u; LONGLONG QuadPart; } LARGE_INTEGER;
#define MEM_COMMIT 0x1000
#define MEM_RESERVE 0x2000
#define MEM_RELEASE 0x8000
#define PAGE_NOACCESS 1
#define PAGE_READONLY 2
#define PAGE_READWRITE 4

/* VirtualAlloc/VirtualFree with whole-allocation release, as the oracles use them. */
static inline size_t lamp_test_page(void) { long page = sysconf(_SC_PAGESIZE); return page > 0 ? (size_t)page : 4096; }
static inline void *VirtualAlloc(void *address, SIZE_T bytes, DWORD type, DWORD protect) {
    (void)type;
    size_t page = lamp_test_page(), total = (bytes + 2 * page - 1) / page * page;
    if (address) return NULL;
    unsigned char *base = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (base == MAP_FAILED) return NULL;
    *(size_t *)base = total;
    if (protect == PAGE_NOACCESS && mprotect(base + page, total - page, PROT_NONE)) { munmap(base, total); return NULL; }
    return base + page;
}
static inline BOOL VirtualFree(void *address, SIZE_T bytes, DWORD type) {
    (void)bytes; (void)type;
    if (!address) return 0;
    unsigned char *base = (unsigned char *)address - lamp_test_page();
    return munmap(base, *(size_t *)base) == 0;
}
static inline BOOL VirtualProtect(void *address, SIZE_T bytes, DWORD protect, DWORD *old) {
    int mode = protect == PAGE_NOACCESS ? PROT_NONE : protect == PAGE_READONLY ? PROT_READ : PROT_READ | PROT_WRITE;
    if (old) *old = PAGE_READWRITE;
    return mprotect(address, bytes, mode) == 0;
}
typedef struct { DWORD dwPageSize; } SYSTEM_INFO;
static inline void GetSystemInfo(SYSTEM_INFO *info) { info->dwPageSize = (DWORD)lamp_test_page(); }

/* PrivateUsage analogue: private data mappings (VmData) of this process. */
typedef struct { DWORD cb; SIZE_T PrivateUsage, PagefileUsage, WorkingSetSize, PeakWorkingSetSize; } PROCESS_MEMORY_COUNTERS_EX;
typedef PROCESS_MEMORY_COUNTERS_EX PROCESS_MEMORY_COUNTERS;
static inline HANDLE GetCurrentProcess(void) { return (HANDLE)(intptr_t)-1; }
static inline BOOL GetProcessMemoryInfo(HANDLE process, PROCESS_MEMORY_COUNTERS *counters, DWORD bytes) {
    (void)process; (void)bytes;
#ifdef __APPLE__
    extern uint64_t lamp_allocated_bytes;
    malloc_statistics_t stats;
    malloc_zone_statistics(NULL, &stats);
    counters->PrivateUsage = counters->PagefileUsage = stats.size_in_use + (SIZE_T)lamp_allocated_bytes;
    counters->WorkingSetSize = counters->PeakWorkingSetSize = 0;
    return 1;
#else
    FILE *status = fopen("/proc/self/status", "r");
    char line[256];
    unsigned long long data = 0, rss = 0, peak = 0;
    if (!status) return 0;
    while (fgets(line, sizeof line, status)) {
        sscanf(line, "VmData: %llu", &data);
        sscanf(line, "VmRSS: %llu", &rss);
        sscanf(line, "VmHWM: %llu", &peak);
    }
    fclose(status);
    counters->PrivateUsage = counters->PagefileUsage = (SIZE_T)data * 1024;
    counters->WorkingSetSize = (SIZE_T)rss * 1024;
    counters->PeakWorkingSetSize = (SIZE_T)peak * 1024;
    return data != 0;
#endif
}

static inline BOOL QueryPerformanceFrequency(LARGE_INTEGER *frequency) { frequency->QuadPart = 1000000000; return 1; }
static inline BOOL QueryPerformanceCounter(LARGE_INTEGER *counter) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    counter->QuadPart = (LONGLONG)now.tv_sec * 1000000000 + now.tv_nsec;
    return 1;
}
#define _byteswap_ulong __builtin_bswap32
#define _byteswap_uint64 __builtin_bswap64

/* Sparse fixture files: holes need filesystem support to stay small. */
typedef int lamp_file;
static inline int lamp_sparse_create(const char *path, uint64_t size, lamp_file *file) {
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return 0;
    *file = fd;
    return ftruncate(fd, (off_t)size) == 0;
}
static inline int lamp_sparse_put(lamp_file fd, uint64_t at, const void *p, DWORD n) {
    const unsigned char *bytes = p;
    while (n) {
        ssize_t done = pwrite(fd, bytes, n, (off_t)at);
        if (done < 0 && errno == EINTR) continue;
        if (done <= 0) return 0;
        bytes += done; at += (uint64_t)done; n -= (DWORD)done;
    }
    return 1;
}
static inline int lamp_sparse_close(lamp_file fd, const char *path, uint64_t *allocated) {
    struct stat info;
    if (fsync(fd) || close(fd) || stat(path, &info)) return 0;
    *allocated = (uint64_t)info.st_blocks * 512;
    return 1;
}
#endif
#endif
