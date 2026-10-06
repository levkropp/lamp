/* Test-only Ogg chain checks. Runtime objects remain assembly.
   chain-oracle check file reference.f32
       Continuous reads in irregular chunks and seeks to link boundaries and
       inside every link must match the reference exactly; links decode
       independently, so the chained reference is the links' own PCM.
       Seeks inside Opus links are checked by dump instead (pre-roll).
   chain-oracle dump file target frames output.f32
       Seeks, discards to the target and writes the next frames.
   chain-oracle reject file [track]  Opening (with track_choice track) must fail.
   chain-oracle cancel-open file A pre-cancelled open must fail cleanly.
   chain-oracle cancel-read file Cancelling during playback stops reads.
   Prints one JSON line. */
#include "lamp-test.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

LAMP_ABI int decoder_open(const lamp_char *);
LAMP_ABI void decoder_close(void);
LAMP_ABI uint64_t decoder_seek(uint64_t);
LAMP_ABI unsigned decoder_read(float *, unsigned);
extern unsigned decode_error, codec_kind, output_rate, chain_active, chain_count, track_choice;
extern unsigned *ogg_cancel_ptr;
extern uint64_t output_frames;
extern unsigned char *chain_links;
struct link { uint64_t begin, end, start, frames, source; unsigned serial, codec, rate, channels, bits, spare; };

static uint32_t seed = 99;
static unsigned next_random(void) { seed = seed * 1103515245u + 12345u; return seed >> 8; }
static float pcm[8192 * 2 + 4];

static int closed_cleanly(void) {
    decoder_close();
    return !chain_active && !chain_links && !chain_count && !decoder_read(pcm, 1);
}

static int discard(uint64_t base, uint64_t target) {
    while (base < target) {
        unsigned count = target - base > 4096 ? 4096 : (unsigned)(target - base);
        unsigned n = decoder_read(pcm, count);
        if (n != count || decode_error) return 0;
        base += n;
    }
    return 1;
}

int lamp_main(int argc, lamp_char **argv) {
    if (argc < 3) return 2;
    const lamp_char *mode = argv[1], *path = argv[2];
    if (!lamp_strcmp(mode, LT("reject"))) {
        /* Structure and timing fail at open; frame contents fail when read. */
        if (argc > 3) track_choice = (unsigned)lamp_atoi(argv[3]);
        int opened = decoder_open(path);
        uint64_t decoded = 0;
        unsigned n;
        if (opened) while ((n = decoder_read(pcm, 4096)) != 0) decoded += n;
        if (!decode_error) return 1;
        unsigned error = decode_error;
        if (!closed_cleanly()) return 1;
        printf("{\"result\":\"rejected\",\"stage\":\"%s\",\"decode_error\":%u}\n", opened ? "read" : "open", error);
        return 0;
    }
    if (!lamp_strcmp(mode, LT("cancel-open"))) {
        unsigned cancel = 1;
        ogg_cancel_ptr = &cancel;
        int opened = decoder_open(path);
        ogg_cancel_ptr = NULL;
        if (opened || !decode_error || !closed_cleanly()) return 1;
        if (!decoder_open(path) || decode_error) return 1;     /* reopen after a cancelled open */
        if (!closed_cleanly()) return 1;
        puts("{\"result\":\"cancelled\"}");
        return 0;
    }
    if (!lamp_strcmp(mode, LT("cancel-read"))) {
        unsigned cancel = 0;
        ogg_cancel_ptr = &cancel;
        if (!decoder_open(path)) return 1;
        uint64_t total = 0;
        unsigned n;
        while ((n = decoder_read(pcm, 4096)) != 0) {
            total += n;
            if (total > output_frames / 2) cancel = 1;
        }
        ogg_cancel_ptr = NULL;
        if (!decode_error || total >= output_frames || !closed_cleanly()) return 1;
        printf("{\"result\":\"cancelled\",\"frames_before_cancel\":%llu}\n", (unsigned long long)total);
        return 0;
    }
    if (!lamp_strcmp(mode, LT("dump"))) {
        if (argc != 6) return 2;
        uint64_t target = lamp_strtou64(argv[3], NULL, 10);
        unsigned frames = (unsigned)lamp_atoi(argv[4]);
        if (frames > 8192 || !decoder_open(path)) return 1;
        uint64_t base = decoder_seek(target);
        if (base > target || decode_error || !discard(base, target)) return 1;
        unsigned n = decoder_read(pcm, frames);
        if (decode_error) return 1;
        FILE *out = lamp_fopen(argv[5], LT("wb"));
        if (!out || fwrite(pcm, 8, n, out) != n) return 2;
        fclose(out);
        if (!closed_cleanly()) return 1;
        printf("{\"result\":\"dumped\",\"base\":%llu,\"frames\":%u}\n", (unsigned long long)base, n);
        return 0;
    }
    if (lamp_strcmp(mode, LT("check")) || argc != 4) return 2;
    FILE *file = lamp_fopen(argv[3], LT("rb"));
    if (!file) return 2;
    fseek(file, 0, SEEK_END);
    long bytes = ftell(file);
    rewind(file);
    if (bytes < 0 || bytes % 8) return 2;
    float *expected = malloc(bytes + 8);
    if (fread(expected, 1, bytes, file) != (size_t)bytes) return 2;
    fclose(file);
    uint64_t frames = (uint64_t)bytes / 8;

    /* Continuous playback across every link. */
    if (!decoder_open(path) || !chain_active || output_frames != frames) {
        fprintf(stderr, "Open: frames %llu, expected %llu\n", (unsigned long long)output_frames, (unsigned long long)frames);
        return 1;
    }
    unsigned links = chain_count;
    struct link *table = malloc(sizeof(struct link) * links);
    memcpy(table, chain_links, sizeof(struct link) * links);
    uint64_t position = 0;
    for (;;) {
        unsigned want = next_random() % 8192 + 1, n = decoder_read(pcm, want);
        if (decode_error) { fprintf(stderr, "Decode error %u at %llu\n", decode_error, (unsigned long long)position); return 1; }
        if (!n) break;
        if (position + n > frames || memcmp(pcm, expected + position * 2, (size_t)n * 8)) {
            fprintf(stderr, "Continuous PCM differs near %llu\n", (unsigned long long)position);
            return 1;
        }
        position += n;
    }
    if (position != frames || !closed_cleanly()) return 1;

    /* Seeks: each link's start and its neighbours, a point inside it, and the end. */
    unsigned seeks = 0, opus_skipped = 0;
    uint64_t most_discarded = 0;
    for (unsigned i = 0; i <= links; i++) {
        uint64_t start = i < links ? table[i].start : frames;
        uint64_t length = i < links ? table[i].frames : 0;
        uint64_t targets[] = {start ? start - 1 : 0, start, start + 1, start + length / 2 + 13, start + length * 7 / 8};
        for (unsigned j = 0; j < sizeof(targets) / sizeof(*targets); j++) {
            uint64_t target = targets[j] > frames ? frames : targets[j];
            unsigned owner = 0;
            while (owner + 1 < links && table[owner + 1].start <= target) owner++;
            if (table[owner].codec == 5 && target > table[owner].start) { opus_skipped++; continue; }
            if (!decoder_open(path)) return 1;
            uint64_t base = decoder_seek(target);
            if (base > target || decode_error) { fprintf(stderr, "Seek %llu base %llu\n", (unsigned long long)target, (unsigned long long)base); return 1; }
            if (base < table[owner].start && target > table[owner].start) return 1;   /* stays in the link */
            if (target - base > most_discarded) most_discarded = target - base;
            if (!discard(base, target)) return 1;
            unsigned count = next_random() % 4096 + 1, n = decoder_read(pcm, count);
            unsigned wanted = frames - target < count ? (unsigned)(frames - target) : count;
            if (n != wanted || decode_error || memcmp(pcm, expected + target * 2, (size_t)n * 8)) {
                fprintf(stderr, "Seek PCM differs at %llu (link %u)\n", (unsigned long long)target, owner);
                return 1;
            }
            if (!closed_cleanly()) return 1;
            seeks++;
        }
    }
    printf("{\"result\":\"passed\",\"links\":%u,\"frames\":%llu,\"rate\":%u,\"seeks\":%u,\"opus_seeks_left_to_dump\":%u,"
           "\"maximum_discarded\":%llu}\n", links, (unsigned long long)frames, output_rate, seeks, opus_skipped,
           (unsigned long long)most_discarded);
    return 0;
}
