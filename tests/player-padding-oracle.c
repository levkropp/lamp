/* Small independent reproduction of shared-mode starvation padding. MIT. */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
extern void pc_test_fill(void);
extern void *pc_test_client,*pc_test_render;
extern unsigned pc_test_buffer_frames,pc_test_done,pc_test_error,engine_exclusive;
extern uint64_t pc_test_read,pc_test_write,pc_test_seek,engine_position;
extern float engine_volume;
#ifdef CURRENT_ENGINE
extern HRESULT pc_test_begin(void);
extern unsigned queue_rate;
#endif
typedef struct{void**v;} Fake;static void*cv[16],*rv[5];static Fake client={cv},render={rv};static float buffer[200];static unsigned padding_frames;
static HRESULT padding(void*p,unsigned*out){(void)p;*out=padding_frames;return S_OK;}
static HRESULT get(void*p,unsigned n,float**out){(void)p;if(n>100)return E_INVALIDARG;*out=buffer;return S_OK;}
static HRESULT release(void*p,unsigned n,unsigned flags){(void)p;(void)n;(void)flags;return S_OK;}
int main(void){
    cv[6]=padding;rv[3]=get;rv[4]=release;pc_test_client=&client;pc_test_render=&render;pc_test_buffer_frames=100;pc_test_write=60;pc_test_read=pc_test_seek=engine_position=0;pc_test_done=pc_test_error=engine_exclusive=0;engine_volume=0;
#ifdef CURRENT_ENGINE
    queue_rate=48000;if(pc_test_begin()!=S_OK)return 3;
#endif
    pc_test_fill();if(pc_test_error || pc_test_read!=60)return 3;
    /* Twenty media frames have left a100-frame packet whose final40 frames
       were inserted silence. The remaining padding80 includes both kinds. */
    padding_frames=80;pc_test_fill();if(pc_test_error)return 3;
    if(engine_position!=20){fprintf(stderr,"padding counterexample: heard%llu expected20\n",(unsigned long long)engine_position);return 2;}
    puts("{\"result\":\"passed\",\"heard_frames\":20,\"remaining_padding\":80}");return 0;
}
