/* Test-only allocation accounting: live malloc bytes, rather than Windows
 * process private commit. This checks release without counting allocator caches.
 */
#ifndef LAMP_MAC_TEST_PSAPI_H
#define LAMP_MAC_TEST_PSAPI_H
#include <malloc/malloc.h>
typedef struct { unsigned cb; size_t PrivateUsage; } PROCESS_MEMORY_COUNTERS_EX;
typedef PROCESS_MEMORY_COUNTERS_EX PROCESS_MEMORY_COUNTERS;
static int GetProcessMemoryInfo(int process, PROCESS_MEMORY_COUNTERS *info, size_t bytes) {
    (void)process; (void)bytes;
    malloc_statistics_t stats;
    malloc_zone_statistics(NULL, &stats);
    info->PrivateUsage = stats.size_in_use;
    return 1;
}
#endif
