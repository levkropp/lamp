/* Windows-only producer/UI handoff stress using the shipping UI functions. */
#include "lamp-test.h"
#include <wchar.h>
typedef struct {
    uint64_t start, frames, cover;
    unsigned index, codec, chapter_count, reserved;
    wchar_t title[1040];
    uint64_t chapters[1024];
} snapshot;
typedef char snapshot_size_check[sizeof(snapshot) == 10312 ? 1 : -1];
LAMP_ABI snapshot *ui_snapshot_probe(unsigned, uint64_t *);
LAMP_ABI void ui_seek_probe(int, uint64_t);
LAMP_ABI void ui_chapter_probe(unsigned);
LAMP_ABI void ui_resume_capture_probe(void);
extern unsigned ui_test_restart, ui_test_resume_enabled, ui_test_resume_pending, ui_test_resume_index;
extern uint64_t ui_test_resume_ms;
LAMP_ABI void ui_file_opened(void);
LAMP_ABI int decoder_open(const lamp_char *);
LAMP_ABI void decoder_close(void);
LAMP_ABI void mem_free(void *);
extern unsigned queue_index, queue_rate;
extern uint64_t queue_output, engine_position, ui_test_count;
extern const lamp_char **queue_paths;
extern snapshot ui_test_ring[64];
extern unsigned ui_count, ui_test_start_index, ui_test_shown_index;
extern unsigned pause_requested;
extern uint64_t ui_thread, ui_test_start_ms, ui_test_shown_frames;
LAMP_ABI uint64_t ui_time_frames_probe(uint64_t, uint32_t);
/* Independent decomposition: multiply whole seconds and the subsecond part,
   checking their product/sum rather than the assembly's 128-bit division. */
static uint64_t expected_frames(uint64_t ms, uint32_t rate) {
    if (!rate) return 0;
    uint64_t whole = ms / 1000, fraction = (ms % 1000) * rate / 1000;
    if (whole > UINT64_MAX / rate) return UINT64_MAX;
    whole *= rate;
    return whole > UINT64_MAX - fraction ? UINT64_MAX : whole + fraction;
}
static unsigned time_frame_checks(void) {
    static const uint64_t times[] = {0, 1, 999, 1000, 4294967295000ULL,
        999999999999999999ULL, INT64_MAX, UINT64_MAX};
    static const uint32_t rates[] = {0, 1, 8000, 48000, 192000, UINT32_MAX};
    unsigned checked = 0;
    for (unsigned r = 0; r < sizeof(rates)/sizeof(rates[0]); r++) {
        for (unsigned t = 0; t < sizeof(times)/sizeof(times[0]); t++) {
            if (ui_time_frames_probe(times[t], rates[r]) != expected_frames(times[t], rates[r])) return 0;
            checked++;
        }
        if (rates[r] >= 1000) {
            uint64_t edge = (UINT64_MAX / rates[r]) * 1000 + ((UINT64_MAX % rates[r]) * 1000) / rates[r];
            for (int d = -2; d <= 2; d++) {
                uint64_t ms = d < 0 ? edge - (uint64_t)-d : edge + (uint64_t)d;
                if (ui_time_frames_probe(ms, rates[r]) != expected_frames(ms, rates[r])) return 0;
                checked++;
            }
        }
    }
    uint64_t seed = 0x829197421631ULL;
    for (unsigned i = 0; i < 1000; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        uint64_t ms = i & 1 ? seed : seed & ((1ULL << 42) - 1);
        uint32_t rate = i % 16 ? (uint32_t)(seed >> 32) : 0;
        if (ui_time_frames_probe(ms, rate) != expected_frames(ms, rate)) return 0;
        checked++;
    }
    return checked;
}
static const lamp_char *paths[2], *names[2];
static volatile LONG finished;

static const lamp_char *basename_of(const lamp_char *path) {
    const lamp_char *name = path;
    while (*path) { if (*path == L'/' || *path == L'\\') name = path + 1; path++; }
    return name;
}

static int valid(const snapshot *s, uint64_t sequence) {
    unsigned index = sequence % 2;
    if (s->index != index || s->start != sequence * 1000 || s->frames != (index ? 1 : 1920) ||
        s->codec != 1 || s->chapter_count != (index ? 0 : 4) || wcscmp(s->title, names[index])) return 0;
    const uint64_t starts[] = {0, 10000000, 25000000, 60000000};
    return index || !memcmp(s->chapters, starts, sizeof(starts));
}

static DWORD WINAPI producer(void *unused) {
    (void)unused;
    for (unsigned i = 0; i < 2000; i++) {
        decoder_close();
        if (!decoder_open(paths[i % 2])) { InterlockedExchange(&finished, -1); return 1; }
        queue_index = i % 2; queue_output = i * 1000ULL;
        ui_file_opened();
    }
    decoder_close(); InterlockedExchange(&finished, 1); return 0;
}

static void release_covers(void) {
    for (unsigned i = 0; i < 64; i++) {
        if (ui_test_ring[i].cover) mem_free((void *)(uintptr_t)ui_test_ring[i].cover);
        ui_test_ring[i].cover = 0;
    }
}

int lamp_main(int argc, lamp_char **argv) {
    if (argc != 4) return 2;
    for (unsigned i = 0; i < 2; i++) { paths[i] = argv[i + 1]; names[i] = basename_of(paths[i]); }
    queue_paths = paths; queue_rate = 48000; engine_position = UINT64_MAX;
    HANDLE thread = CreateThread(NULL, 0, producer, NULL, 0, NULL);
    if (!thread) return 2;
    unsigned reads = 0, claimed = 0; uint64_t previous = 0;
    ULONGLONG deadline = GetTickCount64() + 120000;
    while (!InterlockedCompareExchange(&finished, 0, 0) || reads < 10000) {
        uint64_t sequence; snapshot *s = ui_snapshot_probe(reads & 1, &sequence);
        if (s) {
            if (sequence < previous || !valid(s, sequence)) {
                fprintf(stderr, "torn UI snapshot at sequence %llu\n", (unsigned long long)sequence); return 1;
            }
            previous = sequence;
            if (s->cover) {
                if (!(reads & 1) || *(uint64_t *)(uintptr_t)s->cover) return 1;
                void *cover = (void *)(uintptr_t)s->cover; s->cover = 0; mem_free(cover); claimed++;
            }
            reads++;
        }
        if (GetTickCount64() > deadline || InterlockedCompareExchange(&finished, 0, 0) < 0) return 1;
        Sleep(0);
    }
    if (WaitForSingleObject(thread, 10000) != WAIT_OBJECT_0 || previous != 1999 || !claimed) return 1;
    CloseHandle(thread);
    /* Remove unclaimed real covers before controlled, post-thread seeding. */
    release_covers();
    /* One 192 kHz frame resamples to one 48 kHz frame. Its positive length
       must remain known, so a 10 ms chapter cannot restart past its end. */
    paths[0] = argv[3]; names[0] = basename_of(paths[0]);
    ui_test_count = 0; queue_index = 0; queue_output = 0; engine_position = 0;
    if (!decoder_open(paths[0])) return 1;
    ui_file_opened();
    uint64_t sequence; snapshot *s = ui_snapshot_probe(0, &sequence);
    if (!s || sequence != 0 || s->frames != 1 || s->chapter_count != 4) return 1;
    ui_count = 1; ui_thread = 1; ui_test_start_index = 0; ui_test_start_ms = 0; pause_requested = 1;
    ui_chapter_probe(6);
    if (ui_test_start_index || ui_test_start_ms || pause_requested != 1) return 1;
    ui_thread = 0; decoder_close(); release_covers();
    paths[0] = argv[1]; names[0] = basename_of(paths[0]);
    unsigned seeded = 0;
    for (unsigned variant = 0; variant < 2; variant++) {
        uint64_t count = (1ULL << 32) + variant * 17;
        for (uint64_t i = count - 64; i < count; i++) {
            snapshot *s = &ui_test_ring[i % 64]; memset(s, 0, sizeof(*s));
            s->start = i * 1000; s->index = i % 2; s->codec = 1;
            s->frames = s->index ? 1 : 1920; s->chapter_count = s->index ? 0 : 4;
            wcscpy(s->title, names[s->index]);
            const uint64_t starts[] = {0, 10000000, 25000000, 60000000}; memcpy(s->chapters, starts, sizeof(starts));
        }
        ui_test_count = count;
        for (uint64_t i = count - 64; i < count; i++) {
            engine_position = i * 1000; uint64_t sequence;
            snapshot *s = ui_snapshot_probe(0, &sequence);
            if (!s || sequence != i || !valid(s, sequence)) return 1;
            seeded++;
        }
        engine_position = (count - 64) * 1000 - 1; uint64_t sequence;
        if (ui_snapshot_probe(0, &sequence)) return 1;
        seeded++;
    }
    /* Defer restart as if a worker were still stopping. The supplied seek
       index must survive even though the latest UI snapshot names file 1. */
    ui_thread = 1; ui_count = 100; ui_test_shown_index = 0; ui_test_shown_frames = 1920;
    pause_requested = 1;
    ui_seek_probe(35, 10);
    if (ui_test_start_index != 35 || ui_test_start_ms != 10 || pause_requested != 1) return 1;
    ui_seek_probe(-1, 200);
    if (ui_test_start_index != 35 || ui_test_start_ms != 10 || pause_requested != 1) return 1;
    ui_test_shown_index = 35; ui_test_shown_frames = 4800000;
    ui_seek_probe(35, 70000);
    if (ui_test_start_index != 35 || ui_test_start_ms != 70000 || pause_requested != 1) return 1;
    ui_seek_probe(35, 200000);
    if (ui_test_start_index != 35 || ui_test_start_ms != 99000 || pause_requested != 1) return 1;
    /* New UI requests already name file 35/99s, while the actual heard
       snapshot still names file 1/750ms. A close/replacement must keep the
       latter pair, without altering the pending launch or pause. */
    ui_test_count = 3; ui_test_restart = 1; ui_test_resume_enabled = 1;
    ui_test_resume_pending = 0; ui_count = 100; engine_position = 84000;
    for (unsigned i = 0; i < 3; i++) {
        memset(&ui_test_ring[i], 0, sizeof(snapshot));
        ui_test_ring[i].start = i * 48000ULL; ui_test_ring[i].index = i;
    }
    ui_resume_capture_probe();
    if (ui_test_resume_pending != 1 || ui_test_resume_index != 1 || ui_test_resume_ms != 750 ||
        ui_test_start_index != 35 || ui_test_start_ms != 99000 || pause_requested != 1) return 1;
    ui_test_resume_pending = 0; ui_test_resume_enabled = 0;
    ui_resume_capture_probe(); if (ui_test_resume_pending) return 1;
    ui_test_resume_enabled = 1; ui_thread = 0;
    ui_resume_capture_probe(); if (ui_test_resume_pending) return 1;
    ui_thread = 1; ui_test_count = 0;
    ui_resume_capture_probe(); if (ui_test_resume_pending) return 1;
    ui_test_count = 3; ui_count = 1;
    ui_resume_capture_probe(); if (ui_test_resume_pending) return 1;
    ui_count = 100; engine_position = 0;
    for (unsigned i = 0; i < 3; i++) ui_test_ring[i].start = 48000 + i * 48000ULL;
    ui_resume_capture_probe(); if (ui_test_resume_pending) return 1;
    ui_thread = 0;
    unsigned frame_checks = time_frame_checks(); if (!frame_checks) return 1;
    printf("{\"real_metadata_publications\":2000,\"coherent_snapshots\":%u,\"owned_covers_freed\":%u,"
           "\"seeded_64bit_queries\":%u,\"paired_seek_checks\":4,\"submillisecond_checks\":2,\"paired_resume_checks\":6,\"time_frame_checks\":%u,"
           "\"expired_snapshots\":\"unavailable\"}\n", reads, claimed, seeded, frame_checks);
    return 0;
}
