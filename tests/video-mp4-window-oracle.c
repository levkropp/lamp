/* Original native MP4 window integration driver. Own hidden HWND only. MIT. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct{BYTE a[64],ctx[1024],b[64];} GPU;
typedef struct{BYTE a[64],ctx[16384],b[64];} Parser;
typedef struct{BYTE a[64],ctx[8192],b[64];} Source;
typedef struct{const BYTE*data;uint64_t bytes;int64_t dts,pts;uint64_t duration,epoch;uint32_t flags,index;int64_t show;uint64_t shown,display;} Packet;
typedef struct{uint32_t ordinal,reserved;volatile DWORD*cancel;uint64_t epoch;} Options;
typedef struct{HWND hwnd;uint64_t played;DWORD paused,eof,error,width,height,steps;int64_t media;uint64_t late;int64_t last_pts;} Report;
typedef struct{const void*data;uint64_t bytes;volatile DWORD*cancel;uint64_t frames;DWORD show,reserved;volatile Report*report;HANDLE event;void*source;void*next;void*reset;uint64_t duration;} Info;
extern int video_mp4_open(void*,const void*,uint64_t,const void*);
extern void video_mp4_close(void*);
extern int video_mp4_h264_reset(void*,void*);
extern int video_mp4_h264_next(void*,void*,void*);
extern void h264_close(void*);
extern HRESULT win_video_open_pool(void*,UINT,UINT,UINT);
extern void win_video_close(void*);
extern HRESULT win_video_play_source(void*,void*,const void*);
static volatile Report report;
static volatile DWORD cancel;
static HANDLE event,thread;
static BYTE*data;static size_t bytes;static uint64_t count,duration,*times,frames,checks;static HRESULT result;
#define CHECK(x) do{++checks;if(!(x)){fprintf(stderr,"mp4-window line%d hr%08lx played%llu paused%lu eof%lu media%lld pts%lld error%08lx\n",__LINE__,result,(unsigned long long)report.played,report.paused,report.eof,(long long)report.media,(long long)report.last_pts,report.error);if(event){InterlockedExchange(&cancel,1);SetEvent(event);}if(thread)WaitForSingleObject(thread,6000);exit(1);}}while(0)
static uint32_t u32(const void*p){uint32_t x;memcpy(&x,p,4);return x;}
static DWORD WINAPI worker(void*unused){
    GPU gpu;Parser hp;Source src;Options options={0,0,&cancel,1};Packet packet;Info info;int r;unsigned i;(void)unused;
    memset(&gpu,0xa5,sizeof(gpu));memset(gpu.ctx,0,sizeof(gpu.ctx));memset(&hp,0xa5,sizeof(hp));memset(hp.ctx,0,sizeof(hp.ctx));memset(&src,0xa5,sizeof(src));memset(src.ctx,0,sizeof(src.ctx));
    CHECK(video_mp4_open(src.ctx,data,bytes,&options));CHECK(video_mp4_h264_reset(src.ctx,hp.ctx));frames=0;
    while((r=video_mp4_h264_next(src.ctx,hp.ctx,&packet))>0){if(r==1)++frames;}CHECK(r==0 && frames>=count);
    result=win_video_open_pool(gpu.ctx,u32(hp.ctx+136),u32(hp.ctx+140),max(1,u32(hp.ctx+14828))+2);CHECK(result==S_OK);
    memset(&info,0,sizeof(info));info.data=data;info.bytes=bytes;info.cancel=&cancel;info.frames=frames;info.report=&report;info.event=event;
    info.source=src.ctx;info.next=video_mp4_h264_next;info.reset=video_mp4_h264_reset;info.duration=duration;
    result=win_video_play_source(gpu.ctx,hp.ctx,&info);
    win_video_close(gpu.ctx);h264_close(hp.ctx);video_mp4_close(src.ctx);
    for(i=0;i<64;++i)CHECK(gpu.a[i]==0xa5 && gpu.b[i]==0xa5 && hp.a[i]==0xa5 && hp.b[i]==0xa5 && src.a[i]==0xa5 && src.b[i]==0xa5);
    return 0;
}
static void wait_for(unsigned what,uint64_t value,DWORD timeout){
    uint64_t end=GetTickCount64()+timeout;
    for(;;){MemoryBarrier();if(what==0 && report.hwnd && report.played>=value)return;if(what==1 && report.paused && report.played>=value)return;if(what==2 && report.steps>=value)return;if(what==3 && report.eof)return;if(what==4 && report.width==value)return;
        CHECK(WaitForSingleObject(thread,0)==WAIT_TIMEOUT && GetTickCount64()<end);Sleep(2);}
}
static void key(UINT k){CHECK(PostMessageW(report.hwnd,WM_KEYDOWN,k,0));}
static void start(void){memset((void*)&report,0,sizeof(report));cancel=0;result=E_UNEXPECTED;ResetEvent(event);thread=CreateThread(0,0,worker,0,0,0);CHECK(thread);wait_for(0,2,10000);}
static void finish(HRESULT expected){CHECK(WaitForSingleObject(thread,6000)==WAIT_OBJECT_0 && result==expected && report.hwnd==0 && report.error==(DWORD)expected);CloseHandle(thread);thread=0;}
static void load(const char*path,void**dst,size_t*size){FILE*f=fopen(path,"rb");long n;CHECK(f);CHECK(!fseek(f,0,SEEK_END));n=ftell(f);CHECK(n>0 && !fseek(f,0,SEEK_SET));*dst=malloc(n);CHECK(*dst && fread(*dst,1,n,f)==(size_t)n);*size=n;fclose(f);}
int main(int argc,char**argv){
    BYTE*timeline;size_t length;uint64_t played,steps,begin,wall;int64_t media,pts;RECT rect;unsigned i;
    CHECK(argc==3 && sizeof(Packet)==80 && sizeof(Info)==88 && sizeof(Report)==64);
    load(argv[1],(void**)&data,&bytes);load(argv[2],(void**)&timeline,&length);CHECK(length>=16 && u32(timeline)==0x314d5448);
    count=u32(timeline+4);memcpy(&duration,timeline+8,8);CHECK(count>=20 && length==16+count*8);times=(uint64_t*)(timeline+16);
    event=CreateEventW(0,TRUE,FALSE,0);CHECK(event);
    /* Pause and resize with an already prepared future frame. The diagnostic
       last-presented timestamp must remain the image actually on the window. */
    start();key(VK_SPACE);wait_for(1,2,3000);Sleep(50);played=report.played;pts=report.last_pts;media=report.media;CHECK(played<count && pts==(int64_t)times[played-1]);Sleep(120);CHECK(report.played==played && report.last_pts==pts && report.media==media);
    CHECK(SetWindowPos(report.hwnd,0,0,0,641,401,SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE));CHECK(GetClientRect(report.hwnd,&rect));wait_for(4,rect.right,3000);Sleep(60);CHECK(report.played==played && report.last_pts==pts && report.media==media);
    for(i=0;i<3;++i){steps=report.steps+1;key(VK_OEM_PERIOD);wait_for(2,steps,3000);wait_for(1,played+1,3000);CHECK(report.played==++played && report.last_pts==(int64_t)times[played-1] && report.media==report.last_pts);}
    /* Every remaining frame is checked by exact independent PTS. This also
       exercises hidden postroll and EOF without an extra step request. */
    while(played<count){steps=report.steps+1;key(VK_OEM_PERIOD);wait_for(2,steps,3000);wait_for(1,played+1,3000);CHECK(report.played==++played && report.last_pts==(int64_t)times[played-1]);}
    wait_for(3,0,3000);CHECK(report.media==(int64_t)duration && report.paused);key(VK_SPACE);wait_for(0,played+2,10000);key(VK_SPACE);wait_for(1,played+2,3000);Sleep(30);CHECK(report.played-played<count && report.last_pts==(int64_t)times[report.played-played-1]);key(VK_ESCAPE);finish(S_OK);
    /* Uninterrupted wall time must follow file duration rather than VUI fps. */
    begin=GetTickCount64();start();wait_for(3,0,15000);wall=GetTickCount64()-begin;CHECK(report.played==count && report.media==(int64_t)duration && report.last_pts==(int64_t)times[count-1]);
    CHECK(wall+100>=duration/1000000 && wall<=duration/1000000+2500);key(VK_ESCAPE);finish(S_OK);
    start();key(VK_SPACE);wait_for(1,2,3000);InterlockedExchange(&cancel,1);SetEvent(event);finish(E_ABORT);
    CloseHandle(event);event=0;free(timeline);free(data);
    printf("{\"result\":\"passed\",\"checks\":%llu,\"visible_frames\":%llu,\"decoded_frames\":%llu,\"duration_ns\":%llu,\"wall_ms\":%llu,\"cases\":[\"pause_future_head\",\"resize_while_paused\",\"exact_timestamp_steps\",\"hidden_preroll_postroll\",\"step_to_eof\",\"replay\",\"file_duration\",\"cancel\"]}\n",(unsigned long long)checks,(unsigned long long)count,(unsigned long long)frames,(unsigned long long)duration,(unsigned long long)wall);return 0;
}
