/* Real transport navigation, using offline PCM as the submitted-buffer oracle. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
extern int lamp_init(void),lamp_audio_init(void),lamp_play_list(const char **,unsigned,uint64_t),lamp_tick(void),lamp_toggle_repeat(void);
extern void lamp_pause(void),lamp_stop(void),lamp_seek(uint64_t),lamp_navigate(unsigned,int);
extern unsigned lamp_state,lamp_rate,lamp_count,queue_target,queue_repeat,lamp_eof;
extern int lamp_index,lamp_error;
extern uint64_t lamp_position,lamp_frames;
extern void probe_reset(void);
extern size_t probe_bytes(void);
extern int probe_equal(const void *,size_t,int);
#define CHECK(x) do {if(!(x)){fprintf(stderr,"line %d: %s (state %u error %d index %d pos %llu frames %llu captured %zu)\n",__LINE__,#x,lamp_state,lamp_error,lamp_index,(unsigned long long)lamp_position,(unsigned long long)lamp_frames,probe_bytes());lamp_stop();return 1;}}while(0)
static unsigned char *pcm[3];static size_t bytes[3];
static int at(int index,uint64_t frame) {
    return lamp_state==2&&lamp_index==index&&lamp_position==frame&&
           probe_bytes()>0&&probe_equal(pcm[index]+frame*8,bytes[index]-frame*8,1);
}
int main(int argc,char **argv) {
    CHECK(argc==7);CHECK(lamp_init());CHECK(!lamp_audio_init());
    for(int i=0;i<3;i++) {
        FILE *f=fopen(argv[4+i],"rb");CHECK(f);fseek(f,0,SEEK_END);bytes[i]=ftell(f);rewind(f);
        pcm[i]=malloc(bytes[i]);CHECK(pcm[i]&&fread(pcm[i],1,bytes[i],f)==bytes[i]);fclose(f);
    }
    const char *paths[]={argv[1],argv[2],argv[3]};queue_target=48000;
    CHECK(lamp_play_list(paths,3,4000));lamp_pause();usleep(80000);CHECK(lamp_state==2);
    lamp_navigate(2,0);CHECK(at(0,0)); // Previous after three seconds restarts.
    lamp_navigate(1,0);CHECK(at(1,0));
    lamp_navigate(2,0);CHECK(at(0,0)); // Previous near the beginning moves back.
    lamp_navigate(2,0);CHECK(at(0,0)); // First entry clamps without repeat.
    lamp_navigate(1,0);CHECK(at(1,0));
    lamp_navigate(3,5);CHECK(at(1,240000)); // Exact resampled relative seek.
    lamp_navigate(3,-60);CHECK(at(1,0));
    lamp_navigate(6,0);CHECK(at(1,240000)); // Chapters come from the heard file.
    lamp_navigate(6,0);CHECK(at(1,480000));
    lamp_navigate(7,0);CHECK(at(1,240000));
    lamp_seek(6*48000);CHECK(at(1,6*48000));
    lamp_navigate(2,0);CHECK(at(1,0));
    lamp_navigate(3,60);CHECK(at(2,0)); // Known EOF contributes no old PCM.
    lamp_navigate(1,0);CHECK(lamp_state==3&&!lamp_error);
    lamp_navigate(4,0);lamp_pause();CHECK(lamp_state==2);lamp_seek(0);CHECK(at(0,0));
    CHECK(lamp_toggle_repeat()==1);
    lamp_navigate(2,0);CHECK(lamp_state==2&&lamp_index==2&&lamp_position==0);
    lamp_navigate(1,0);CHECK(at(0,0));
    CHECK(lamp_toggle_repeat()==0);lamp_stop();

    // A short file reaches decoder EOF while its submitted PCM is unheard.
    CHECK(lamp_play_list(paths+2,1,0));lamp_pause();CHECK(lamp_state==2&&lamp_eof);
    CHECK(lamp_toggle_repeat()==1);lamp_pause();
    for(int i=0;i<60;i++){lamp_tick();usleep(10000);}
    CHECK(lamp_state==1&&!lamp_error);CHECK(lamp_toggle_repeat()==0);
    for(int i=0;i<100&&lamp_tick()==1;i++)usleep(10000);
    CHECK(lamp_state==3);lamp_stop();
    for(int i=0;i<3;i++)free(pcm[i]);
    puts("{\"result\":\"passed\",\"scope\":\"real Core Audio next/previous, restart threshold, repeat wrap and late toggle, exact resampled relative/chapter seeks, pause retention and navigation EOF\"}");return 0;
}
