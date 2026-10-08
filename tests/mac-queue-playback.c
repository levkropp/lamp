/* Drives the shipping assembly backend against real Core Audio, with the
   test-only observer checking every enqueued sample and buffer boundary. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
extern int lamp_init(void),lamp_audio_init(void),lamp_play_list(const char **,unsigned,uint64_t),lamp_tick(void);
extern void lamp_pause(void),lamp_stop(void),lamp_seek(uint64_t);
extern unsigned lamp_state,lamp_rate,lamp_count,queue_target,queue_repeat,queue_index,lamp_decode_error;
extern int lamp_index,lamp_error;
extern uint64_t lamp_position,lamp_frames;
extern const char **lamp_paths;
extern void probe_reset(void);
extern size_t probe_bytes(void);
extern int probe_equal(const void *,size_t,int);
#define CHECK(x) do {if(!(x)){fprintf(stderr,"line %d: %s (state %u error %d index %d pos %llu frames %llu captured %zu)\n",__LINE__,#x,lamp_state,lamp_error,lamp_index,(unsigned long long)lamp_position,(unsigned long long)lamp_frames,probe_bytes());lamp_stop();return 1;}}while(0)
static int finish(void) {for(int n=0;n<500;n++){int state=lamp_tick();if(state!=1&&state!=2)return state;usleep(10000);}return -1;}
int main(int argc,char **argv) {
    CHECK(argc==5);CHECK(lamp_init());CHECK(!lamp_audio_init());
    FILE *f=fopen(argv[4],"rb");CHECK(f);fseek(f,0,SEEK_END);long bytes=ftell(f);rewind(f);
    unsigned char *reference=malloc(bytes);CHECK(reference&&fread(reference,1,bytes,f)==(size_t)bytes);fclose(f);
    const char *paths[]={argv[1],argv[2],argv[3]};
    queue_target=48000;
    probe_reset();CHECK(lamp_play_list(paths,3,0));CHECK(lamp_rate==48000&&lamp_count==3);
    CHECK(finish()==3);CHECK(lamp_index==2&&lamp_position==2400&&lamp_frames==2400);
    CHECK(probe_equal(reference,bytes,0));lamp_stop();

    CHECK(lamp_play_list(paths,3,0));lamp_pause();CHECK(lamp_state==2);
    CHECK(lamp_index==0&&queue_index>0&&lamp_frames==4800);
    probe_reset();lamp_seek(2400);CHECK(lamp_state==2&&lamp_index==0&&lamp_position==2400);
    CHECK(probe_equal(reference+2400*8,bytes-2400*8,1));
    uint64_t position=lamp_position;usleep(180000);CHECK(lamp_position==position&&lamp_state==2);
    lamp_pause();
    for(int n=0;n<200&&lamp_index==0;n++){lamp_tick();usleep(10000);}
    lamp_pause();CHECK(lamp_state==2&&lamp_index==1&&lamp_frames==52800);
    probe_reset();lamp_seek(9600);CHECK(lamp_state==2&&lamp_index==1&&lamp_position==9600);
    CHECK(probe_equal(reference+(4800+9600)*8,bytes-(4800+9600)*8,1));
    lamp_pause();CHECK(finish()==3);
    CHECK(probe_equal(reference+(4800+9600)*8,bytes-(4800+9600)*8,0));

    // A replacement may borrow the current array. Copy it before stopping.
    CHECK(lamp_play_list(lamp_paths,lamp_count,50));lamp_pause();CHECK(lamp_state==2&&lamp_position>=2400);
    lamp_seek(0);CHECK(lamp_state==2&&lamp_index==0&&lamp_position==0);lamp_stop();
    const char *missing[]={argv[1],"/nonexistent/lamp-queue-test"};
    probe_reset();CHECK(lamp_play_list(missing,2,0));CHECK(finish()==4&&lamp_decode_error);
    CHECK(probe_equal(reference,4800*8,0));lamp_stop();

    queue_repeat=1;
    const char *shorts[]={argv[1],argv[3]};
    probe_reset();CHECK(lamp_play_list(shorts,2,0));usleep(350000);lamp_pause();CHECK(lamp_state==2);
    usleep(80000);position=lamp_position;size_t frozen=probe_bytes();usleep(50000);
    CHECK(lamp_position==position&&probe_bytes()==frozen);
    size_t captured=probe_bytes(),cycle=(4800+2400)*8;
    unsigned char *loop=malloc(captured+cycle);CHECK(loop);
    for(size_t off=0;off<captured;off+=cycle){memcpy(loop+off,reference,4800*8);memcpy(loop+off+4800*8,reference+bytes-2400*8,2400*8);}
    CHECK(captured>cycle&&probe_equal(loop,captured,0));lamp_stop();queue_repeat=0;
    CHECK(!lamp_count&&!lamp_paths&&!lamp_position);
    free(loop);free(reference);
    puts("{\"result\":\"passed\",\"checks\":7,\"scope\":\"real Core Audio; exact submitted queue PCM, paused heard-file and resampled seeks, EOF, borrowed-list replacement, error drain, gapless repeat\"}");return 0;
}
