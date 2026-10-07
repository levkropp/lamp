/* Test the shipping decoder's published audio ordinals, including reopen
   and failure clearing. No parser or runtime replacement is linked. */
#include "lamp-test.h"
LAMP_ABI int decoder_open(const lamp_char *);
LAMP_ABI void decoder_close(void);
extern unsigned track_choice, audio_tracks_count, audio_track_selected, decode_error;

int lamp_main(int argc, lamp_char **argv) {
    if (argc != 5) return 2;
    unsigned choice = lamp_atoi(argv[2]), count = lamp_atoi(argv[3]), selected = lamp_atoi(argv[4]);
    track_choice = choice;
    int opened = decoder_open(argv[1]);
    if (audio_tracks_count != count || audio_track_selected != selected || opened != (count != 0)) {
        printf("opened=%d count=%u selected=%u error=%u expected_count=%u expected_selected=%u\n",
               opened, audio_tracks_count, audio_track_selected, decode_error, count, selected);
        return 1;
    }
    if (!opened && decode_error != 101) return 1;
    decoder_close();
    if (opened) {
        /* A failed reopen must not expose the preceding file's catalog. */
        track_choice = 0x7fffffff;
        if (decoder_open(argv[1]) || audio_tracks_count || audio_track_selected || decode_error != 101) return 1;
        decoder_close();
        track_choice = choice;
        if (!decoder_open(argv[1]) || audio_tracks_count != count || audio_track_selected != selected) return 1;
        decoder_close();
    }
    printf("{\"audio_tracks\":%u,\"selected_ordinal\":%u,\"requested_ordinal\":%u,"
           "\"failure_clears_catalog\":true,\"reopen\":true}\n", count, selected, choice);
    return 0;
}
