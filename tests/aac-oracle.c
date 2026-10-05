/* Test-only AAC coverage probe. Runtime objects remain assembly.
   aac-oracle file   Decodes the whole file and prints one JSON line with the
                     frame count, decode_error and the aac_features bits of
                     the coding tools the stream used. */
#include "lamp-test.h"
#include <stdint.h>
#include <stdio.h>

LAMP_ABI int decoder_open(const lamp_char *);
LAMP_ABI void decoder_close(void);
LAMP_ABI unsigned decoder_read(float *, unsigned);
extern unsigned decode_error, codec_kind, aac_features, aac_channels;
static float pcm[4096 * 2];

int lamp_main(int argc, lamp_char **argv) {
    if (argc != 2) return 2;
    if (!decoder_open(argv[1])) {
        printf("{\"result\":\"rejected\",\"decode_error\":%u}\n", decode_error);
        return 0;
    }
    uint64_t frames = 0;
    unsigned n;
    while ((n = decoder_read(pcm, 4096)) != 0) frames += n;
    unsigned features = aac_features, channels = aac_channels, error = decode_error, kind = codec_kind;
    decoder_close();
    printf("{\"result\":\"%s\",\"frames\":%llu,\"codec_kind\":%u,\"channels\":%u,\"features\":%u,\"decode_error\":%u}\n",
           error ? "failed" : "decoded", (unsigned long long)frames, kind, channels, features, error);
    return 0;
}
