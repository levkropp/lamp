/* Test-only Windows protected-memory vocabulary for the existing packet oracle.
 * Apple Silicon has 16 KiB pages; the runner substitutes the native page size.
 */
#ifndef LAMP_MAC_TEST_WINDOWS_H
#define LAMP_MAC_TEST_WINDOWS_H
#include <stdint.h>
#include <stddef.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdlib.h>
#include <wchar.h>
#include <fcntl.h>
#include <sys/stat.h>
typedef uint32_t DWORD;
typedef size_t SIZE_T;
typedef int HANDLE;
typedef struct { unsigned long dwPageSize; } SYSTEM_INFO;
typedef union { int64_t QuadPart; } LARGE_INTEGER;
static void GetSystemInfo(SYSTEM_INFO *info) { info->dwPageSize = sysconf(_SC_PAGE_SIZE); }
static HANDLE GetCurrentProcess(void) { return getpid(); }
#define GENERIC_READ 1
#define GENERIC_WRITE 2
#define CREATE_ALWAYS 2
#define FILE_ATTRIBUTE_NORMAL 0
#define FILE_BEGIN SEEK_SET
#define INVALID_HANDLE_VALUE -1
static HANDLE CreateFileW(const char *name, unsigned access, unsigned share,
                         void *security, unsigned disposition, unsigned flags, void *template) {
    (void)access; (void)share; (void)security; (void)disposition; (void)flags; (void)template;
    return open(name, O_RDWR | O_CREAT | O_TRUNC, 0600);
}
static int SetFilePointerEx(HANDLE h, LARGE_INTEGER offset, LARGE_INTEGER *out, int origin) {
    off_t at = lseek(h, offset.QuadPart, origin);
    if (out) out->QuadPart = at;
    return at >= 0;
}
static int SetEndOfFile(HANDLE h) { off_t n=lseek(h,0,SEEK_CUR); return n>=0 && !ftruncate(h,n); }
static int WriteFile(HANDLE h, const void *p, DWORD n, DWORD *done, void *overlap) {
    (void)overlap; ssize_t result=write(h,p,n); *done=result<0?0:(DWORD)result; return result>=0;
}
static int FlushFileBuffers(HANDLE h) { return !fsync(h); }
static int CloseHandle(HANDLE h) { return !close(h); }
static DWORD GetCompressedFileSizeW(const char *name, DWORD *high) {
    struct stat s; if (stat(name,&s)) return 0;
    uint64_t bytes=(uint64_t)s.st_blocks*512; *high=(DWORD)(bytes>>32); return (DWORD)bytes;
}
#define _byteswap_ulong __builtin_bswap32
#define MEM_RESERVE 0x2000
#define MEM_COMMIT 0x1000
#define MEM_RELEASE 0x8000
#define PAGE_READWRITE 4
#define PAGE_NOACCESS 1
static size_t test_mapping_size;
static void *VirtualAlloc(void *address, size_t size, unsigned flags, unsigned protection) {
    (void)address; (void)flags; (void)protection;
    test_mapping_size = size;
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    return p == MAP_FAILED ? NULL : p;
}
static int VirtualProtect(void *p, size_t size, unsigned protection, DWORD *previous) {
    *previous = PAGE_READWRITE;
    return !mprotect(p, size, protection == PAGE_NOACCESS ? PROT_NONE : PROT_READ | PROT_WRITE);
}
static int VirtualFree(void *p, size_t size, unsigned flags) {
    (void)size; (void)flags;
    return !munmap(p, test_mapping_size);
}
#endif
