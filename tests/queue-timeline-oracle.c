/* Dense audible queues, exact restarted PCM, and bounded history queries.
   The test-only probe exports private state solely for seeded 64-bit/wrap
   checks; real queue reads exercise publication and empty-file coalescing. */
#include "lamp-test.h"
#ifndef _WIN32
#include <stdatomic.h>
#include <pthread.h>
#include <sched.h>
#endif
LAMP_ABI int queue_begin(const lamp_char **, unsigned);
LAMP_ABI unsigned queue_read(float *, unsigned);
LAMP_ABI void queue_start(uint64_t);
LAMP_ABI int queue_heard_probe(uint64_t, uint64_t *);
LAMP_ABI uint64_t queue_navigate_probe(unsigned, int, uint64_t, int);
LAMP_ABI void decoder_close(void);
extern unsigned queue_index, queue_rate, queue_target, queue_repeat, decode_error, queue_failures;
extern uint64_t queue_test_count, queue_test_marks[][2];
extern uint64_t queue_output;
extern LAMP_ABI void (*queue_announce)(void);
static unsigned announcements;
static LAMP_ABI void announce(void) { announcements++; }

static int heard(uint64_t at, int want, uint64_t start) {
    uint64_t got_start = UINT64_MAX;
    int got = queue_heard_probe(at, &got_start);
    if (got != want || got_start != start) {
        fprintf(stderr, "heard(%llu): file %d at %llu, wanted %d at %llu\n",
            (unsigned long long)at, got, (unsigned long long)got_start,
            want, (unsigned long long)start);
        return 0;
    }
    return 1;
}

static unsigned seeded(void) {
    /* Positions and list indices are independently specified here. The
       logical ordinal crosses 2^32 and the physical ring wraps. */
    const uint64_t capacity = 524288, count = (1ULL << 32) + 12345;
    const uint64_t oldest = count - capacity;
    for (uint64_t i = oldest; i < count; i++) {
        queue_test_marks[i % capacity][0] = 100 + 2 * i;
        queue_test_marks[i % capacity][1] = i % 100;
    }
    queue_test_count = count;
    if (!heard(100 + 2 * oldest - 1, -1, 0) ||
        !heard(100 + 2 * oldest, oldest % 100, 100 + 2 * oldest) ||
        !heard(UINT64_MAX, (count - 1) % 100, 100 + 2 * (count - 1))) return 0;
    for (uint64_t i = 0; i < 10000; i++) {
        uint64_t ordinal = oldest + (i * 7919 % capacity);
        if (!heard(100 + 2 * ordinal + (i & 1), ordinal % 100, 100 + 2 * ordinal)) return 0;
    }
    queue_test_count = 1;
    queue_test_marks[0][0] = 100;
    queue_test_marks[0][1] = 17;
    if (!heard(99, -1, 0) || !heard(100, 17, 100)) return 0;
    queue_test_count = 0;
    if (!heard(0, -1, 0) || !heard(UINT64_MAX, -1, 0)) return 0;
    return 10007;
}

static int dense(const lamp_char *path, const lamp_char *reference_path, unsigned rate) {
    FILE *file = lamp_fopen(reference_path, LT("rb"));
    if (!file) return 0;
    fseek(file, 0, SEEK_END); long bytes = ftell(file); rewind(file);
    if (bytes <= 0 || bytes % 8) return 0;
    unsigned frames = bytes / 8;
    unsigned char *reference = malloc(bytes);
    if (!reference || fread(reference, 1, bytes, file) != (size_t)bytes) return 0;
    fclose(file);
    const lamp_char *paths[100];
    for (unsigned i = 0; i < 100; i++) paths[i] = path;
    queue_target = rate; announcements = 0; queue_announce = announce;
    if (!queue_begin(paths, 100) || queue_rate != rate) return 0;
    /* The destination ends at a protected page. */
    SYSTEM_INFO info; GetSystemInfo(&info);
    unsigned capacity = 131072, usable = capacity * 8;
    unsigned char *memory = VirtualAlloc(NULL, usable + info.dwPageSize,
        MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    DWORD old;
    if (!memory || !VirtualProtect(memory + usable, info.dwPageSize, PAGE_NOACCESS, &old)) return 0;
    unsigned count = queue_read((float *)memory, capacity);
    if (count != capacity || queue_index < 64 || decode_error) return 0;
    for (unsigned i = 0; i < count; i++)
        if (memcmp(memory + i * 8, reference + i % frames * 8, 8)) return 0;
    unsigned queries = 0;
    for (unsigned i = 0; i < count; i += 137) {
        if (!heard(i, i / frames, i / frames * frames)) return 0;
        queries++;
    }
    for (unsigned i = 0; i < count / frames; i++) {
        if (!heard(i * frames, i, i * frames) ||
            !heard((i + 1) * frames - 1, i, i * frames)) return 0;
        queries += 2;
    }
    unsigned ahead = queue_index;
    const struct { unsigned command; int heard, want; uint64_t ms, target; } jumps[] = {
        {1, 0, 1, 5, 0}, {2, 17, 16, 5, 0}, {3, 27, 27, 10, 10},
        {6, 0, 0, 0, 10}, {6, 0, 0, 10, 25}, {7, 0, 0, 25, 10}
    };
    for (unsigned i = 0; i < sizeof(jumps) / sizeof(*jumps); i++) {
        uint64_t got = queue_navigate_probe(jumps[i].command, jumps[i].heard, jumps[i].ms, 0);
        if (got != jumps[i].target || queue_index != (unsigned)jumps[i].want) return 0;
        queue_start(got);
        unsigned at = got * rate / 1000;
        unsigned n = queue_read((float *)memory, 256);
        if (n != 256 || at + n > frames || decode_error || memcmp(memory, reference + at * 8, n * 8)) {
            fprintf(stderr, "restart PCM %u at %llu ms\n", i, (unsigned long long)got); return 0;
        }
    }
    if (queue_navigate_probe(1, -1, 0, 0) != UINT64_MAX) return 0;
    decoder_close(); VirtualFree(memory, 0, MEM_RELEASE); free(reference);
    queue_announce = NULL; queue_target = 0;
    printf("{\"frames_prebuffered\":%u,\"decoded_file\":%u,\"timeline_queries\":%u,"
           "\"exact_pcm_restarts\":6,\"guarded_output\":true,\"rate\":%u}\n",
           count, ahead, queries, rate);
    return 1;
}

static int empty_files(const lamp_char *audio, const lamp_char *empty) {
    const lamp_char *paths[1002];
    paths[0] = audio; for (unsigned i = 1; i < 1001; i++) paths[i] = empty; paths[1001] = audio;
    float *pcm = malloc(4096 * 8);
    if (!pcm) return 0;
    queue_target = 0; announcements = 0; queue_announce = announce;
    if (!queue_begin(paths, 1002)) return 0;
    unsigned count = queue_read(pcm, 4096);
    if (count != 3840 || queue_test_count != 2 || announcements != 1001 || decode_error || queue_failures ||
        !heard(0, 0, 0) || !heard(1919, 0, 0) || !heard(1920, 1001, 1920)) {
        fprintf(stderr, "empty files: frames %u marks %llu announcements %u error %u\n",
            count, (unsigned long long)queue_test_count, announcements, decode_error); return 0;
    }
    decoder_close(); free(pcm); queue_announce = NULL;
    printf("{\"empty_files\":1000,\"timeline_boundaries\":2,\"later_file_announcements\":1001,\"frames\":3840}\n");
    return 1;
}

static int repeated(const lamp_char *path) {
    const lamp_char *paths[100]; for (unsigned i = 0; i < 100; i++) paths[i] = path;
    float *pcm = malloc(4096 * 8); if (!pcm) return 0;
    queue_repeat = 1; queue_target = 0; announcements = 0; queue_announce = announce;
    if (!queue_begin(paths, 100) || queue_read(pcm, 4096) != 4096 || decode_error ||
        announcements != 4095 || queue_test_count != 4096) return 0;
    for (unsigned i = 0; i < 4096; i++) if (!heard(i, i % 100, i)) return 0;
    decoder_close(); free(pcm); queue_repeat = 0; queue_announce = NULL;
    printf("{\"single_frame_files\":4096,\"timeline_queries\":4096,\"gapless_list_wraps\":40,\"later_file_announcements\":4095}\n");
    return 1;
}

#ifdef _WIN32
static volatile LONG writer_done;
static void writer_status_set(int value) { InterlockedExchange(&writer_done, value); }
static int writer_status(void) { return InterlockedCompareExchange(&writer_done, 0, 0); }
static DWORD WINAPI timeline_writer(void *unused) {
#else
static atomic_int writer_done;
static void writer_status_set(int value) { atomic_store(&writer_done, value); }
static int writer_status(void) { return atomic_load(&writer_done); }
static void *timeline_writer(void *unused) {
#endif
    (void)unused;
    float pcm[4096 * 2];
    int okay = queue_read(pcm, 4096) == 4096 && !decode_error;
    writer_status_set(okay ? 1 : -1);
    return 0;
}

static int concurrent(const lamp_char *path) {
    const lamp_char *paths[100]; for (unsigned i = 0; i < 100; i++) paths[i] = path;
    queue_repeat = 1; queue_target = 0;
    if (!queue_begin(paths, 100)) return 0;
    /* Seed a full, wrapped window, then let real one-frame opens overwrite
       its oldest records while another thread queries that boundary. */
    const uint64_t count = (1ULL << 32) + 4, oldest = count - 524288;
    for (uint64_t i = oldest; i < count; i++) {
        queue_test_marks[i % 524288][0] = i;
        queue_test_marks[i % 524288][1] = (i + 1) % 100;
    }
    queue_test_count = count; queue_output = count - 1;
#ifdef _WIN32
    HANDLE thread = CreateThread(NULL, 0, timeline_writer, NULL, 0, NULL);
    if (!thread) return 0;
#else
    pthread_t thread;
    if (pthread_create(&thread, NULL, timeline_writer, NULL)) return 0;
#endif
    LARGE_INTEGER first, now, frequency;
    QueryPerformanceCounter(&first); QueryPerformanceFrequency(&frequency);
    unsigned reads = 0;
    while (!writer_status() || reads < 10000) {
        uint64_t at = oldest + (reads * 7919ULL % 8192), start;
        int index = queue_heard_probe(at, &start);
        if ((index >= 0 && (start != at || index != (int)((at + 1) % 100))) ||
            (index < 0 && at >= oldest + 4096)) return 0;
        if (writer_status() < 0) return 0;
        reads++;
        if (!(reads % 256)) {
            QueryPerformanceCounter(&now);
            if (now.QuadPart - first.QuadPart > frequency.QuadPart * 120) return 0;
#ifdef _WIN32
            Sleep(0);
#else
            sched_yield();
#endif
        }
    }
#ifdef _WIN32
    if (WaitForSingleObject(thread, 10000) != WAIT_OBJECT_0) return 0;
    CloseHandle(thread);
#else
    if (pthread_join(thread, NULL)) return 0;
#endif
    if (queue_test_count != count + 4095) return 0;
    for (unsigned i = 0; i < 8192; i++) {
        uint64_t at = oldest + i;
        if (!heard(at, i < 4095 ? -1 : (int)((at + 1) % 100), i < 4095 ? 0 : at)) return 0;
    }
    decoder_close(); queue_repeat = 0;
    printf("{\"concurrent_history_queries\":%u,\"real_overwrites\":4095,"
           "\"final_retention_queries\":8192,\"mixed_start_index_records\":0}\n", reads);
    return 1;
}

static int tiny(const lamp_char *first, const lamp_char *resampled) {
    const lamp_char *paths[] = {first, resampled};
    float pcm[4];
    for (unsigned file = 0; file < 2; file++) {
        queue_target = 48000;
        if (!queue_begin(paths + file, 1)) return 0;
        for (unsigned command = 6; command <= 7; command++) {
            uint64_t target = queue_navigate_probe(command, 0, 0, 0);
            if (target != 0 || queue_index != 0 || decode_error) return 0;
            queue_start(target);
            if (queue_read(pcm, 2) != 1 || decode_error) return 0;
        }
        decoder_close();
    }
    queue_target = 0;
    printf("{\"known_submillisecond_files\":2,\"ignored_future_chapter_seeks\":4,"
           "\"frames_per_open\":1,\"session_rate\":48000}\n");
    return 1;
}

int lamp_main(int argc, lamp_char **argv) {
    if (argc == 1) {
        unsigned queries = seeded(); if (!queries) return 1;
        printf("{\"seeded_history_queries\":%u,\"retained_boundaries\":524288,"
               "\"logical_count_above_2_to_32\":true,\"expired_history\":\"unknown\"}\n", queries);
        return 0;
    }
    if (argc == 5 && !lamp_strcmp(argv[1], LT("dense"))) return dense(argv[2], argv[3], lamp_atoi(argv[4])) ? 0 : 1;
    if (argc == 4 && !lamp_strcmp(argv[1], LT("empty"))) return empty_files(argv[2], argv[3]) ? 0 : 1;
    if (argc == 3 && !lamp_strcmp(argv[1], LT("repeat"))) return repeated(argv[2]) ? 0 : 1;
    if (argc == 3 && !lamp_strcmp(argv[1], LT("concurrent"))) return concurrent(argv[2]) ? 0 : 1;
    if (argc == 4 && !lamp_strcmp(argv[1], LT("tiny"))) return tiny(argv[2], argv[3]) ? 0 : 1;
    return 2;
}
