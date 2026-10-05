/* Test-only resampler checks. Runtime objects remain assembly.
   usage: resample-oracle in-rate out-rate input.f32 output.f32
   Runs the assembly resampler over stereo float input delivered in irregular
   chunks, writes its output, and compares every output frame with an
   independent direct evaluation of the specified filter: a Kaiser-windowed
   sinc (beta 9, 64 zero crossings per side at the lower rate's cutoff of
   0.955 of its Nyquist frequency), evaluated at the exact instant k*in/out and
   normalized to unit DC gain. Restarts from later input frames must
   reproduce the continuous output exactly. Prints one JSON line. */
#include "lamp-test.h"
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned (LAMP_ABI *source_fn)(float *, unsigned);
LAMP_ABI int resample_open(unsigned, unsigned, source_fn);
LAMP_ABI uint64_t resample_reset(uint64_t);
LAMP_ABI unsigned resample_read(float *, unsigned);
LAMP_ABI void resample_close(void);
extern unsigned resample_half, decode_error;

static float *input;
static uint64_t input_frames, cursor;
static uint32_t seed = 12345;
static unsigned next_random(void) { seed = seed * 1103515245u + 12345u; return seed >> 8; }

static LAMP_ABI unsigned source(float *out, unsigned frames) {
    unsigned n = next_random() % 1500 + 1;
    if (n > frames) n = frames;
    if (n > input_frames - cursor) n = (unsigned)(input_frames - cursor);
    memcpy(out, input + cursor * 2, (size_t)n * 8);
    cursor += n;
    return n;
}

static long double bessel_i0(long double y) {
    long double q = y * y / 4, sum = 1, term = 1;
    for (int k = 1; k < 500; k++) {
        term = term * q / ((long double)k * k);
        sum += term;
        if (term <= sum * 1e-21L) break;
    }
    return sum;
}

static float *run(unsigned in, unsigned out, uint64_t start, uint64_t *first, uint64_t *count) {
    uint64_t capacity = (input_frames * out + in - 1) / in + 16;
    float *pcm = malloc(capacity * 8 + 8);
    cursor = start;
    *first = resample_reset(start);
    uint64_t produced = 0;
    for (;;) {
        unsigned want = next_random() % 3000 + 1;
        if (produced + want > capacity) want = (unsigned)(capacity - produced);
        if (!want) break;
        unsigned n = resample_read(pcm + produced * 2, want);
        if (!n) break;
        produced += n;
    }
    *count = produced;
    return pcm;
}

int lamp_main(int argc, lamp_char **argv) {
    if (argc != 5) return 2;
    unsigned in = (unsigned)lamp_atoi(argv[1]), out = (unsigned)lamp_atoi(argv[2]);
    FILE *file = lamp_fopen(argv[3], LT("rb"));
    if (!file) return 2;
    fseek(file, 0, SEEK_END);
    long bytes = ftell(file);
    rewind(file);
    if (bytes <= 0 || bytes % 8) return 2;
    input = malloc(bytes);
    if (fread(input, 1, bytes, file) != (size_t)bytes) return 2;
    fclose(file);
    input_frames = (uint64_t)bytes / 8;
    if (!resample_open(in, out, source)) { fprintf(stderr, "resample_open failed\n"); return 1; }
    uint64_t first, frames;
    float *pcm = run(in, out, 0, &first, &frames);
    uint64_t expected = (input_frames * out + in - 1) / in;
    if (first || frames != expected || decode_error) {
        fprintf(stderr, "Output length %llu, expected %llu\n", (unsigned long long)frames, (unsigned long long)expected);
        return 1;
    }
    FILE *output = lamp_fopen(argv[4], LT("wb"));
    if (!output || fwrite(pcm, 8, frames, output) != frames) return 2;
    fclose(output);

    /* Independent direct evaluation. */
    long double ratio = out < in ? (long double)out / in : 1;
    long double fc = 0.955L * ratio, beta = 9, i0_beta = bessel_i0(beta);
    long double pi = 3.141592653589793238462643383279502884L;
    long half = in > out ? (long)(((uint64_t)in * 64 + out - 1) / out) : 64;
    half = (half + 1) & ~1L;
    if (half != (long)resample_half) { fprintf(stderr, "Half width %ld, assembly %u\n", half, resample_half); return 1; }
    double max_error = 0;
    for (uint64_t k = 0; k < frames; k++) {
        uint64_t whole = k * in / out, rest = k * in % out;
        long double offset = (long double)rest / out, sum = 0, left = 0, right = 0;
        for (long t = 0; t < 2 * half; t++) {
            int64_t j = (int64_t)whole - half + 1 + t;
            long double x = (long double)(t - half + 1) - offset, q = x / half, h;
            if (1 - q * q <= 0) h = 0;
            else {
                long double w = bessel_i0(beta * sqrtl(1 - q * q)) / i0_beta;
                h = x == 0 ? fc : sinl(pi * fc * x) / (pi * x);
                h *= w;
            }
            sum += h;
            if (j >= 0 && (uint64_t)j < input_frames) {
                left += h * input[j * 2];
                right += h * input[j * 2 + 1];
            }
        }
        double el = fabs((double)(left / sum) - pcm[k * 2]), er = fabs((double)(right / sum) - pcm[k * 2 + 1]);
        if (el > max_error) max_error = el;
        if (er > max_error) max_error = er;
    }
    if (max_error > 2e-6) { fprintf(stderr, "Reference error %.3g\n", max_error); return 1; }

    /* Restarts after a seek: outputs from the returned frame match exactly. */
    unsigned restarts = 0;
    uint64_t starts[] = {1, (uint64_t)resample_half, input_frames / 3, input_frames / 2 + 17, input_frames - 1};
    for (unsigned i = 0; i < sizeof(starts) / sizeof(*starts); i++) {
        uint64_t later_first, later_frames;
        float *later = run(in, out, starts[i], &later_first, &later_frames);
        uint64_t remaining = later_first < frames ? frames - later_first : 0;
        if (later_frames != remaining || (remaining && memcmp(later, pcm + later_first * 2, later_frames * 8))) {
            fprintf(stderr, "Restart at %llu differs\n", (unsigned long long)starts[i]);
            return 1;
        }
        uint64_t lowest = (starts[i] + resample_half - 1) * out;
        if (later_first * in < lowest) return 1;
        free(later);
        restarts++;
    }
    resample_close();
    printf("{\"in\":%u,\"out\":%u,\"input_frames\":%llu,\"output_frames\":%llu,\"half_width\":%u,"
           "\"maximum_reference_error\":%.3g,\"restarts\":%u}\n", in, out, (unsigned long long)input_frames,
           (unsigned long long)frames, resample_half, max_error, restarts);
    return 0;
}
