/* Original silent native engine/snapshot integration check. Test-only. MIT. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct{uint64_t epoch;int64_t ns;uint32_t state,reserved;uint64_t frames;uint32_t rate,reserved2;} Snapshot;
extern int engine_clock_snapshot(void*);
extern int engine_play(const wchar_t*);
extern void engine_pause(void),engine_stop(void);
extern volatile uint32_t engine_stop_requested,pause_requested,engine_ready,engine_seek_seconds,engine_exclusive;
extern volatile uint64_t engine_position;
extern float engine_volume;
extern uint32_t queue_target;
static HANDLE thread;static wchar_t path[32768];static volatile DWORD result;static uint64_t checks,previous_epoch,reads;
#define CHECK(x) do{++checks;if(!(x)){fprintf(stderr,"native-clock line%d result%lu ready%lu paused%lu position%llu\n",__LINE__,result,engine_ready,pause_requested,(unsigned long long)engine_position);engine_stop();if(thread)WaitForSingleObject(thread,6000);exit(2);}}while(0)
static DWORD WINAPI worker(void*unused){(void)unused;result=engine_play(path);return result;}
static Snapshot read_clock(void){Snapshot s;CHECK(engine_clock_snapshot(&s));CHECK(s.epoch && s.rate==48000 && !s.reserved && !s.reserved2);CHECK(s.ns==(int64_t)(s.frames/48000*1000000000+s.frames%48000*1000000000/48000));++reads;return s;}
static Snapshot wait_clock(unsigned state,uint64_t frames){uint64_t deadline=GetTickCount64()+6000,last=0,epoch=0;Snapshot s={0};
    for(;;){if(engine_clock_snapshot(&s) && s.epoch>previous_epoch){CHECK(s.rate==48000 && s.epoch>=epoch && (s.epoch!=epoch || s.frames>=last));epoch=s.epoch;last=s.frames;if(s.state==state && s.frames>=frames)return read_clock();}
        if(GetTickCount64()>=deadline)fprintf(stderr,"wanted state%u frames%llu mode%lu priorEpoch%llu last epoch%llu frames%llu state%u\n",state,(unsigned long long)frames,engine_exclusive,(unsigned long long)previous_epoch,(unsigned long long)s.epoch,(unsigned long long)s.frames,s.state);
        CHECK(WaitForSingleObject(thread,0)==WAIT_TIMEOUT && GetTickCount64()<deadline);Sleep(2);}}
static void start(const char*input,unsigned exclusive,unsigned seek,unsigned paused){
    CHECK(MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,input,-1,path,32768));engine_volume=0;CHECK(engine_volume==0);engine_exclusive=exclusive;queue_target=48000;engine_seek_seconds=seek;pause_requested=paused;engine_stop_requested=0;engine_ready=0;result=UINT32_MAX;
    thread=CreateThread(0,0,worker,0,0,0);CHECK(thread);
}
static void join(unsigned expected_state){Snapshot s;CHECK(WaitForSingleObject(thread,6000)==WAIT_OBJECT_0 && !result);CloseHandle(thread);thread=0;s=read_clock();CHECK(s.state==expected_state && s.frames==engine_position && s.epoch>previous_epoch);previous_epoch=s.epoch;}
int main(int argc,char**argv){Snapshot a,b;unsigned mode;uint64_t stopped[2],ended[2];CHECK(argc==4 && sizeof(Snapshot)==40);
    for(mode=0;mode<2;++mode){
        start(argv[1],mode,0,0);a=wait_clock(0,12000);engine_pause();a=wait_clock(1,a.frames);Sleep(100);a=read_clock();Sleep(180);b=read_clock();CHECK(!memcmp(&a,&b,40) && a.frames==engine_position && a.state==1);engine_pause();b=wait_clock(0,a.frames+12000);engine_stop();join(5);stopped[mode]=engine_position;
        start(argv[1],mode,1,1);a=wait_clock(1,48000);CHECK(a.frames==48000);Sleep(150);b=read_clock();CHECK(!memcmp(&a,&b,40));engine_pause();wait_clock(0,60000);engine_stop();join(5);
        start(argv[2],mode,0,0);CHECK(WaitForSingleObject(thread,6000)==WAIT_OBJECT_0);join(4);a=read_clock();CHECK(a.frames==1001 && a.ns==20854166);ended[mode]=a.frames;
        start(argv[3],mode,0,0);CHECK(WaitForSingleObject(thread,6000)==WAIT_OBJECT_0);join(4);a=read_clock();CHECK(!a.frames && !a.ns);
    }
    puts("Muted output: engine_volume=0 before every engine_play call.");
    printf("{\"result\":\"passed\",\"checks\":%llu,\"snapshots\":%llu,\"shared_stopped_frames\":%llu,\"exclusive_stopped_frames\":%llu,\"shared_eof_frames\":%llu,\"exclusive_eof_frames\":%llu,\"epochs\":%llu,\"cases\":[\"shared_and_exclusive\",\"coherent_rate_position\",\"pause_hold\",\"resume\",\"paused_seek_epoch\",\"stop\",\"exact_partial_tail_eof\",\"empty_eof\"]}\n",(unsigned long long)checks,(unsigned long long)reads,(unsigned long long)stopped[0],(unsigned long long)stopped[1],(unsigned long long)ended[0],(unsigned long long)ended[1],(unsigned long long)previous_epoch);return 0;
}
