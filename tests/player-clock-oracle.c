/* Original CPU-only COM fake driving the real shared render function. MIT. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct{uint64_t epoch;int64_t ns;uint32_t state,reserved;uint64_t frames;uint32_t rate,reserved2;} Snapshot;
extern HRESULT pc_test_begin(void),pc_test_pause(void),pc_test_ended(void);
extern HRESULT pc_test_started(void);
extern void pc_test_fill(void),pc_test_stopped(void);
extern int engine_clock_snapshot(void*);
extern void *pc_test_client,*pc_test_render;
extern unsigned pc_test_buffer_frames,pc_test_done,pc_test_error,engine_exclusive,queue_rate;
extern unsigned pc_test_start_flag;
extern uint64_t pc_test_write,pc_test_read,pc_test_seek,engine_position;
extern float pc_test_pcm[],engine_volume;
extern unsigned char pc_test_clock[];
typedef struct{void**vtable;} Fake;
static void*client_vtable[16],*render_vtable[5];static Fake client={client_vtable},render={render_vtable};
static uint64_t accepted,consumed,checks,real_total,hash=1469598103934665603ULL;
static unsigned request,get_calls,release_calls,fail_get,fail_release;static float samples[4096];
typedef struct{uint64_t start,real;} Packet;static Packet packets[100000];static unsigned packet_count;
#define CHECK(x) do{++checks;if(!(x)){fprintf(stderr,"player-clock line%d accepted%llu consumed%llu real%llu read%llu error%08x\n",__LINE__,(unsigned long long)accepted,(unsigned long long)consumed,(unsigned long long)real_total,(unsigned long long)pc_test_read,pc_test_error);exit(2);}}while(0)
static uint64_t u64(const void*p){uint64_t x;memcpy(&x,p,8);return x;}
static HRESULT padding(void*self,unsigned*out){CHECK(self==&client && accepted>=consumed && accepted-consumed<=pc_test_buffer_frames);*out=(unsigned)(accepted-consumed);return S_OK;}
static HRESULT get(void*self,unsigned frames,float**out){CHECK(self==&render);++get_calls;if(fail_get)return E_FAIL;CHECK(!request && frames && frames<=2048 && frames<=pc_test_buffer_frames-(accepted-consumed));request=frames;memset(samples,0xa7,sizeof(samples));*out=samples;return S_OK;}
static HRESULT release(void*self,unsigned frames,unsigned flags){unsigned i;uint64_t available=pc_test_write-pc_test_read,real=available<frames?available:frames;CHECK(self==&render && request==frames && flags==0);++release_calls;request=0;if(fail_release)return E_FAIL;
    for(i=0;i<frames;++i){float expected=i<real?0.25f:0;CHECK(samples[2*i]==expected && samples[2*i+1]==expected);}CHECK(packet_count<100000);packets[packet_count++]=(Packet){accepted,real};accepted+=frames;real_total+=real;return S_OK;}
static void snapshot(unsigned state){Snapshot s;uint64_t expected=pc_test_seek;unsigned i;for(i=0;i<packet_count;++i){uint64_t n=consumed>packets[i].start?consumed-packets[i].start:0;if(n>packets[i].real)n=packets[i].real;expected+=n;}
    CHECK(engine_clock_snapshot(&s));CHECK(s.frames==expected && s.ns==(int64_t)(expected/queue_rate*1000000000+(expected%queue_rate)*1000000000/queue_rate) && s.state==state && s.rate==queue_rate && !s.reserved && !s.reserved2);CHECK(engine_position==expected);for(i=0;i<40;++i){hash^=((unsigned char*)&s)[i];hash*=1099511628211ULL;}}
static void begin(uint64_t seek){unsigned i;accepted=consumed=real_total=packet_count=request=get_calls=release_calls=fail_get=fail_release=0;pc_test_read=pc_test_write=0;pc_test_done=pc_test_error=engine_exclusive=pc_test_start_flag=0;pc_test_buffer_frames=100;queue_rate=48000;pc_test_seek=engine_position=seek;engine_volume=1;pc_test_client=&client;pc_test_render=&render;for(i=0;i<262144*2;++i)pc_test_pcm[i]=0.25f;CHECK(pc_test_begin()==S_OK);snapshot(2);}
static void fill(unsigned state){pc_test_fill();CHECK(!pc_test_error && !request && pc_test_read==real_total);snapshot(state);}
static unsigned random_state=0x52454e44;
static unsigned rnd(void){random_state^=random_state<<13;random_state^=random_state>>17;random_state^=random_state<<5;return random_state;}
int main(void){unsigned i,j;uint64_t prior,epoch;Snapshot s;
    client_vtable[6]=padding;render_vtable[3]=get;render_vtable[4]=release;
    begin(123456);pc_test_write=60;fill(2);CHECK(pc_test_started()==S_OK);snapshot(0);consumed=20;fill(0);CHECK(engine_position==123476);consumed=60;fill(2);consumed=90;pc_test_write+=80;fill(2);consumed=accepted-20;fill(0);
    CHECK(pc_test_pause()==S_OK);snapshot(1);prior=engine_position;CHECK(pc_test_pause()==S_OK && engine_position==prior);pc_test_done=1;consumed=accepted;fill(2);consumed=accepted;fill(2);CHECK(pc_test_read==pc_test_write);CHECK(pc_test_ended()==S_OK);snapshot(4);pc_test_stopped();snapshot(4);
    CHECK(engine_clock_snapshot(&s));epoch=s.epoch;
    for(j=0;j<32;++j){begin(j*997);CHECK(pc_test_started()==S_OK);CHECK(engine_clock_snapshot(&s) && s.epoch>epoch);epoch=s.epoch;for(i=0;i<1000;++i){unsigned state=2,k;uint64_t gap=accepted-consumed;consumed+=gap?rnd()%(gap+1):0;if((rnd()&3)!=0)pc_test_write+=rnd()%40;
        pc_test_fill();CHECK(!pc_test_error && !request && pc_test_read==real_total);
        for(k=0;k<packet_count;++k)if(consumed>=packets[k].start && consumed-packets[k].start<packets[k].real)state=0;
        snapshot(state);}
        consumed=accepted;pc_test_done=1;pc_test_fill();CHECK(!pc_test_error);consumed=accepted;pc_test_fill();CHECK(!pc_test_error && pc_test_read==pc_test_write);CHECK(pc_test_ended()==S_OK);snapshot(4);}
    /* A failed GetBuffer/ReleaseBuffer never publishes/consumes unaccepted PCM. */
    for(j=0;j<2;++j){begin(0);pc_test_write=100;if(j)fail_release=1;else fail_get=1;pc_test_fill();CHECK(pc_test_error==0x80004005 && !pc_test_read && !accepted && !u64(pc_test_clock+32) && !u64(pc_test_clock+40));pc_test_stopped();CHECK(engine_clock_snapshot(&s) && s.state==6);}
    begin(0);pc_test_write=100;fill(2);consumed=35;CHECK(pc_test_pause()==S_OK);snapshot(1);pc_test_stopped();snapshot(5);
    printf("{\"result\":\"passed\",\"checks\":%llu,\"render_iterations\":32000,\"fingerprint\":\"%016llx\",\"scope\":\"Real shared render function and clock helpers with CPU-only fake COM clients; no audio endpoint\"}\n",(unsigned long long)checks,(unsigned long long)hash);return 0;
}
