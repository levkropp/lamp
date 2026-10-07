/* Direct shared-codec packet/capacity check, separate from the track layer. */
#include "lamp-test.h"
LAMP_ABI int ac3_track_open(const void *, unsigned, const void *, unsigned);
LAMP_ABI int ac3_track_samples(const void *, unsigned);
LAMP_ABI unsigned ac3_track_decode(const void *, unsigned, float *, unsigned);
LAMP_ABI void ac3_track_reset(void);
LAMP_ABI void ac3_track_close(void);
extern unsigned decode_error;

int lamp_main(int argc, lamp_char **argv) {
    if (argc != 2) return 2;
    FILE *file = lamp_fopen(argv[1], LT("rb"));
    if (!file) return 2;
    fseek(file, 0, SEEK_END); long bytes = ftell(file); rewind(file);
    if (bytes < 8 || bytes > 1048576) return 2;
    unsigned char *data = malloc(bytes);
    if (!data || fread(data, 1, bytes, file) != (size_t)bytes) return 2;
    fclose(file);
    if (!ac3_track_open(NULL, 0, data, (unsigned)bytes)) return 1;
    unsigned expected = 0;
    for (unsigned pos=0; pos<(unsigned)bytes;) {
        unsigned size = 2 * (((data[pos+2]&7)<<8 | data[pos+3])+1);
        if (size<8 || pos+size>(unsigned)bytes) return 2;
        unsigned counts[4] = {1,2,3,6};
        expected += counts[(data[pos+4]>>4)&3]*256;
        pos += size;
    }
    if ((unsigned)ac3_track_samples(data, (unsigned)bytes) != expected) return 1;
    float *pcm = malloc((expected*2+4)*sizeof(float));
    if (!pcm) return 2;
    for (unsigned i=0;i<expected*2+4;i++) pcm[i]=12345.0f;
    /* A packet holding several frames must honor capacity at every boundary. */
    if (ac3_track_decode(data, (unsigned)bytes, pcm+2, expected) != expected || decode_error) return 1;
    if (pcm[0]!=12345 || pcm[1]!=12345 || pcm[expected*2+2]!=12345 || pcm[expected*2+3]!=12345) return 1;
    ac3_track_reset(); decode_error=0;
    for (unsigned i=0;i<expected*2+4;i++) pcm[i]=12345.0f;
    if (ac3_track_decode(data, (unsigned)bytes, pcm+2, expected-1) || decode_error!=100) return 1;
    if (pcm[0]!=12345 || pcm[1]!=12345 || pcm[expected*2+2]!=12345 || pcm[expected*2+3]!=12345) return 1;
    if (pcm[expected*2]!=12345 || pcm[expected*2+1]!=12345) return 1;
    ac3_track_close(); free(pcm); free(data);
    printf("{\"result\":\"bounded\",\"packet_frames\":%u}\n",expected);
    return 0;
}
