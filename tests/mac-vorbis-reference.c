/* Test-only Xiph encoder/decoder. No reference C enters the LAMP runtime. */
#include <vorbis/vorbisenc.h>
#include <vorbis/vorbisfile.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int encode(const char *path, int rate, int channels, double seconds, float quality) {
    FILE *out = fopen(path, "wb");
    vorbis_info info; vorbis_comment comment; vorbis_dsp_state dsp;
    vorbis_block block; ogg_stream_state stream; ogg_packet packet;
    ogg_page page; ogg_packet h1, h2, h3;
    if (!out) return 1;
    vorbis_info_init(&info);
    if (vorbis_encode_init_vbr(&info, channels, rate, quality)) return 1;
    vorbis_comment_init(&comment);
    vorbis_analysis_init(&dsp, &info); vorbis_block_init(&dsp, &block);
    ogg_stream_init(&stream, 0x1a64);
    vorbis_analysis_headerout(&dsp, &comment, &h1, &h2, &h3);
    ogg_stream_packetin(&stream, &h1); ogg_stream_packetin(&stream, &h2);
    ogg_stream_packetin(&stream, &h3);
    while (ogg_stream_flush(&stream, &page)) {
        fwrite(page.header, 1, page.header_len, out);
        fwrite(page.body, 1, page.body_len, out);
    }
    long frames = (long)llround(rate * seconds), at = 0;
    int eof = 0;
    while (!eof) {
        int n = frames - at > 1024 ? 1024 : (int)(frames - at);
        float **pcm = vorbis_analysis_buffer(&dsp, n ? n : 1);
        for (int i = 0; i < n; ++i) for (int c = 0; c < channels; ++c)
            pcm[c][i] = .125f * sin(2 * acos(-1.) * (997 + c * 31) * (at + i) / rate);
        at += n; vorbis_analysis_wrote(&dsp, n);
        while (vorbis_analysis_blockout(&dsp, &block) == 1) {
            vorbis_analysis(&block, NULL); vorbis_bitrate_addblock(&block);
            while (vorbis_bitrate_flushpacket(&dsp, &packet)) {
                ogg_stream_packetin(&stream, &packet);
                while (ogg_stream_pageout(&stream, &page)) {
                    fwrite(page.header, 1, page.header_len, out);
                    fwrite(page.body, 1, page.body_len, out);
                    if (ogg_page_eos(&page)) eof = 1;
                }
            }
        }
    }
    ogg_stream_clear(&stream); vorbis_block_clear(&block);
    vorbis_dsp_clear(&dsp); vorbis_comment_clear(&comment); vorbis_info_clear(&info);
    return fclose(out) != 0;
}

static int decode(const char *path) {
    OggVorbis_File file;
    if (ov_fopen(path, &file)) return 1;
    unsigned channels = ov_info(&file, -1)->channels;
    long n; int logical; float **pcm;
    while ((n = ov_read_float(&file, &pcm, 1024, &logical)) > 0)
        for (long i = 0; i < n; ++i) for (unsigned c = 0; c < channels; ++c)
            if (fwrite(&pcm[c][i], sizeof(float), 1, stdout) != 1) return 1;
    ov_clear(&file);
    return n < 0;
}
int main(int argc, char **argv) {
    if ((argc == 6 || argc == 7) && !strcmp(argv[1], "encode"))
        return encode(argv[2], atoi(argv[3]), atoi(argv[4]), atof(argv[5]), argc==7 ? atof(argv[6]) : .4f);
    if (argc == 3 && !strcmp(argv[1], "decode")) return decode(argv[2]);
    return 2;
}
