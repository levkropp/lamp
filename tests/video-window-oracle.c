/* Test-only original Win32 window driver. Addresses only its own HWND. MIT. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct { BYTE before[64],ctx[1024],after[64]; } GPU;
typedef struct { BYTE before[64],ctx[16384],after[64]; } Parser;
typedef struct { HWND hwnd; uint64_t played; DWORD paused,eof,error,width,height,steps; int64_t media; uint64_t late,reserved; } Report;
typedef struct { const void *data; uint64_t bytes; volatile DWORD *cancel; uint64_t frames; DWORD show,reserved; volatile Report *report; HANDLE event; } Info;
extern int h264_open(void*,const void*,uint64_t,const volatile DWORD*);
extern int h264_next(void*); extern void h264_close(void*);
extern HRESULT win_video_open(void*,UINT,UINT); extern void win_video_close(void*);
extern HRESULT win_video_open_refs(void*,UINT,UINT,UINT);
extern HRESULT win_video_open_pool(void*,UINT,UINT,UINT);
extern HRESULT win_video_play(void*,void*,const Info*);
static volatile Report report;
static volatile DWORD cancel;
static HANDLE event,thread;
static BYTE *data; static size_t bytes; static HRESULT result;
static uint64_t checks,frames;
#define CHECK(x) do { ++checks; if(!(x)) { fprintf(stderr,"window-oracle line%d hr%08lx count%llu paused%lu eof%lu error%08lx\n",__LINE__,result,(unsigned long long)report.played,report.paused,report.eof,report.error); if(event){InterlockedExchange(&cancel,1);SetEvent(event);} if(thread)WaitForSingleObject(thread,6000); exit(1); } } while(0)
static UINT u32(const void *p) { UINT n; memcpy(&n,p,4);return n; }
static DWORD WINAPI worker(void *unused) {
    GPU gpu; Parser parser; Info info; int next; UINT i; (void)unused;
    memset(&gpu,0xa5,sizeof(gpu));memset(gpu.ctx,0,sizeof(gpu.ctx));
    memset(&parser,0xa5,sizeof(parser));memset(parser.ctx,0,sizeof(parser.ctx));
    CHECK(h264_open(parser.ctx,data,bytes,&cancel));
    while((next=h264_next(parser.ctx))==1){} CHECK(next==0);
    memcpy(&frames,parser.ctx+48,8);CHECK(frames>=60);
    result=win_video_open_pool(gpu.ctx,u32(parser.ctx+136),u32(parser.ctx+140),max(1,u32(parser.ctx+14828))+2);CHECK(SUCCEEDED(result));
    memset(&info,0,sizeof(info));info.data=data;info.bytes=bytes;info.cancel=&cancel;
    info.frames=frames;info.report=&report;info.event=event;
    result=win_video_play(gpu.ctx,parser.ctx,&info);
    win_video_close(gpu.ctx);h264_close(parser.ctx);
    for(i=0;i<64;++i)CHECK(gpu.before[i]==0xa5 && gpu.after[i]==0xa5 && parser.before[i]==0xa5 && parser.after[i]==0xa5);
    return 0;
}
/* All report reads are volatile, naturally aligned diagnostic snapshots. */
static void wait_for(int what,uint64_t value,DWORD timeout) {
    uint64_t deadline=GetTickCount64()+timeout;
    for(;;) {
        MemoryBarrier();
        if(what==0 && report.hwnd && report.played>=value)return;
        if(what==1 && report.paused && report.played>=value)return;
        if(what==2 && report.steps>=value)return;
        if(what==3 && report.width==(DWORD)value)return;
        if(what==4 && report.eof)return;
        if(what==5 && !report.paused && report.played>=value)return;
        CHECK(WaitForSingleObject(thread,0)==WAIT_TIMEOUT);
        CHECK(GetTickCount64()<deadline);Sleep(2);
    }
}
static void key(UINT value,LPARAM flags) { CHECK(PostMessageW(report.hwnd,WM_KEYDOWN,value,flags)); }
static void start(void) {
    memset((void*)&report,0,sizeof(report));cancel=0;result=E_UNEXPECTED;ResetEvent(event);
    thread=CreateThread(0,0,worker,0,0,0);CHECK(thread!=0);wait_for(0,2,6000);
}
static void finish(HRESULT expected) {
    CHECK(WaitForSingleObject(thread,6000)==WAIT_OBJECT_0);CHECK(result==expected);
    CHECK(report.hwnd==0 && report.error==(DWORD)expected);CloseHandle(thread);thread=0;
}
int main(int argc,char **argv) {
    FILE *f;long length;uint64_t count;int64_t media;RECT rect;HWND owned;
    CHECK(sizeof(Info)==56 && sizeof(Report)==64);CHECK(argc==2);
    f=fopen(argv[1],"rb");CHECK(f!=0);CHECK(!fseek(f,0,SEEK_END));length=ftell(f);CHECK(length>0);
    CHECK(!fseek(f,0,SEEK_SET));data=malloc(length);CHECK(data!=0);bytes=length;
    CHECK(fread(data,1,bytes,f)==bytes);fclose(f);
    event=CreateEventW(0,TRUE,FALSE,0);CHECK(event!=0);
    start();owned=report.hwnd;key(VK_SPACE,0);wait_for(1,2,3000);Sleep(50);
    count=report.played;media=report.media;Sleep(150);CHECK(report.played==count && report.media==media);
    key(VK_SPACE,0x40000000);Sleep(80);CHECK(report.paused && report.played==count);
    key(VK_OEM_PERIOD,0);wait_for(2,1,3000);Sleep(50);CHECK(report.played==count+1 && report.paused);count=report.played;
    key(VK_OEM_PERIOD,0);wait_for(2,2,3000);Sleep(50);CHECK(report.played==count+1 && report.paused);
    CHECK(SetWindowPos(owned,0,0,0,641,401,SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE));
    CHECK(GetClientRect(owned,&rect));wait_for(3,rect.right,3000);CHECK(report.height==(DWORD)rect.bottom);
    count=report.played;Sleep(80);CHECK(report.played==count);
    key(VK_SPACE,0);wait_for(5,count+2,3000);
    /* Simulate this hidden host's minimized/restore notifications without desktop input. */
    CHECK(PostMessageW(owned,WM_SIZE,SIZE_MINIMIZED,0));Sleep(100);count=report.played;media=report.media;
    Sleep(150);CHECK(report.played==count && report.media==media);
    CHECK(PostMessageW(owned,WM_SIZE,SIZE_RESTORED,MAKELPARAM(rect.right,rect.bottom)));
    wait_for(0,count+2,3000);wait_for(4,0,6000);CHECK(report.played==frames && report.paused);
    CHECK(report.media==3000000000LL); /* 90 frames /30fps, last frame held for its duration. */
    count=report.played;key(VK_SPACE,0);wait_for(5,count+2,3000);CHECK(PostMessageW(owned,WM_CLOSE,0,0));finish(S_OK);
    CHECK(!IsWindow(owned));
    start();key(VK_SPACE,0);wait_for(1,2,3000);
    InterlockedExchange(&cancel,1);CHECK(SetEvent(event));finish(E_ABORT);
    start();key(VK_ESCAPE,0);finish(S_OK);
    /* Stepping the final output must reach EOF without an extra input request. */
    start();key(VK_SPACE,0);wait_for(1,2,3000);Sleep(30);
    while(report.played<frames){uint64_t step=report.steps+1;key(VK_OEM_PERIOD,0);wait_for(2,step,3000);wait_for(1,report.played,3000);}
    wait_for(4,0,3000);CHECK(report.paused && report.played==frames && report.media==3000000000LL);
    key(VK_ESCAPE,0);finish(S_OK);
    CloseHandle(event);event=0;free(data);
    printf("{\"result\":\"passed\",\"checks\":%llu,\"source_frames\":%llu,\"cases\":[\"pause\",\"autorepeat\",\"two_steps\",\"resize\",\"minimize\",\"eof\",\"replay\",\"close\",\"cancel\",\"escape\",\"step_to_eof\"]}\n",(unsigned long long)checks,(unsigned long long)frames);
    return 0;
}
