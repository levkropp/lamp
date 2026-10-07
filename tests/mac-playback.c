/* Test-only C drives the same assembly engine used by AppKit and the CLI. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
extern int lamp_init(void), lamp_audio_init(void), lamp_play(const char *), lamp_tick(void);
extern void lamp_pause(void), lamp_stop(void), lamp_seek(uint64_t), lamp_set_volume(float);
extern unsigned lamp_state, sample_rate;
extern int lamp_error;
extern uint64_t lamp_position, total_frames;
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"failed line %d: %s (state %u, error %d)\n",__LINE__,#x,lamp_state,lamp_error); return 1; } } while (0)
int main(int argc, char **argv) {
    CHECK(argc == 2 || (argc==3 && !strcmp(argv[2],"--empty")));
    CHECK(lamp_init());
    CHECK(!lamp_audio_init());
    if (argc==3) {
        CHECK(lamp_play(argv[1])); CHECK(lamp_state==3 && !total_frames && !lamp_position);
        lamp_pause();CHECK(lamp_state==3);
        lamp_seek(0);CHECK(lamp_state==3 && !lamp_position);
        lamp_stop();CHECK(lamp_state==0);
        puts("Core Audio: zero-frame open/pause/seek/stop passed.");return 0;
    }
    for (int pass = 0; pass < 3; ++pass) {
        CHECK(lamp_play(argv[1]));
        CHECK(lamp_state == 1);
        usleep(180000);
        lamp_pause(); CHECK(lamp_state == 2);
        usleep(80000); uint64_t at = lamp_position;
        usleep(150000); CHECK(lamp_position == at);
        lamp_set_volume(.2f);
        lamp_seek(sample_rate / 2); CHECK(lamp_state == 2);
        CHECK(lamp_position == sample_rate / 2);
        lamp_pause(); CHECK(lamp_state == 1);
        usleep(180000);
        CHECK(lamp_position > sample_rate / 2);
        lamp_seek(total_frames); // EOF must finish without a hang.
        for (int n = 0; n < 100 && lamp_tick() == 1; ++n) usleep(20000);
        CHECK(lamp_state == 3);
        lamp_stop(); CHECK(lamp_state == 0);
    }
    CHECK(lamp_play(argv[1]));
    for (int n=0; n<250 && lamp_tick()==1; ++n) usleep(20000);
    CHECK(lamp_state==3 && lamp_position==total_frames);
    lamp_stop();
    CHECK(!lamp_play("/nonexistent/lamp-test-file")); CHECK(lamp_state == 4);
    lamp_stop();
    puts("Core Audio: 3 open/pause/paused-seek/resume/EOF/stop cycles, natural EOF and failed-open recovery passed.");
    return 0;
}
