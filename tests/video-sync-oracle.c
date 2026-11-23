/* Original test-only queue/clock oracle. Never linked into the player. MIT. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#ifdef _WIN32
#include <windows.h>
#define ABI
#else
#include <sys/mman.h>
#include <unistd.h>
#define ABI __attribute__((ms_abi))
#endif

enum { CAP=32, BYTES=1152, WAIT=0, PRESENT=1, DROP=2, EMPTY=3, HOLD=4 };
typedef struct { int64_t pts, duration; uint64_t token, epoch; } Frame;
typedef struct { uint64_t epoch; int64_t media; uint32_t state, reserved; } Clock;
typedef struct { Frame frame; int64_t wait; } Result;
typedef struct {
    uint64_t epoch; int64_t target, clock; uint32_t seen, count;
    uint64_t late, presented, dropped; int64_t last_pts;
    uint32_t have_pts; unsigned char pad[60]; Frame frames[CAP];
} Context;
typedef struct {
    unsigned char before[64]; Context ctx; unsigned char after[64];
} Guarded;
typedef struct { Frame f; uint64_t serial; } Item;
typedef struct {
    uint64_t epoch, serial, late, presented, dropped;
    int64_t target, clock, last_pts; unsigned seen, count, have_pts; Item items[CAP];
} Model;
extern int ABI video_sync_init(Context*,uint64_t);
extern int ABI video_sync_epoch(Context*,uint64_t,int64_t);
extern int ABI video_sync_push(Context*,const Frame*);
extern int ABI video_sync_drain(Context*,Frame*);
extern int ABI video_sync_select(Context*,const Clock*,Result*);
extern int64_t ABI video_sync_sample_ns(uint64_t,uint32_t);
static uint64_t checks, rng=0x9b3028abfcde8311ULL, operations;
#define CHECK(x) do { ++checks; if(!(x)) { fprintf(stderr,"video-sync line %d operation %llu\n",__LINE__,(unsigned long long)operations); exit(1); } } while(0)
static uint64_t random64(void) { rng^=rng<<13; rng^=rng>>7; rng^=rng<<17; return rng; }
static void guards(const Guarded *g) {
    unsigned i; for(i=0;i<64;++i) { CHECK(g->before[i]==0xa5); CHECK(g->after[i]==0xa5); }
}
static unsigned first(const Model *m) {
    unsigned i,j=0;
    for(i=1;i<m->count;++i)
        if(m->items[i].f.pts<m->items[j].f.pts ||
           (m->items[i].f.pts==m->items[j].f.pts && m->items[i].serial<m->items[j].serial)) j=i;
    return j;
}
static Frame remove_first(Model *m) {
    unsigned i=first(m); Frame f=m->items[i].f;
    m->items[i]=m->items[--m->count]; return f;
}
static int model_push(Model *m,Frame f) {
    unsigned i;
    if(f.duration<=0 || f.pts>INT64_MAX-f.duration || !f.token || !f.epoch || f.epoch!=m->epoch) return -1;
    for(i=0;i<m->count;++i) if(m->items[i].f.token==f.token) return -1;
    if(m->count==CAP) return 0;
    m->items[m->count].f=f; m->items[m->count++].serial=m->serial++; return 1;
}
static int model_select(Model *m,Clock c,Result *r) {
    unsigned i,j; int action; Frame f; int64_t end;
    if(!c.epoch || c.epoch!=m->epoch || c.media<0 || c.state>3 || c.reserved || (m->seen && c.media<m->clock)) return -1;
    m->seen=1; m->clock=c.media;
    memset(r,0,sizeof(*r)); r->wait=-1;
    if(c.state==1 || c.state==2) return HOLD;
    if(!m->count) return EMPTY;
    j=first(m); f=m->items[j].f; end=f.pts+f.duration;
    action=PRESENT;
    if((m->have_pts && f.pts<m->last_pts) || end<=m->target) action=DROP;
    else if(c.state!=3 && f.pts>c.media) { r->wait=f.pts-c.media; return WAIT; }
    else if(c.state!=3 && c.media>end && (uint64_t)c.media-(uint64_t)end>m->late) {
        /* A superseding frame must actually be due. Unsorted bag reference. */
        for(i=0;i<m->count;++i) if(i!=j && m->items[i].f.pts<=c.media) { action=DROP; break; }
    }
    r->frame=remove_first(m); r->wait=0;
    if(action==PRESENT) { m->last_pts=f.pts; m->have_pts=1; if(m->presented!=UINT64_MAX) ++m->presented; }
    else if(m->dropped!=UINT64_MAX) ++m->dropped;
    return action;
}
static void state(const Context *c,const Model *m) {
    unsigned i,j; CHECK(c->count==m->count); CHECK(c->epoch==m->epoch);
    CHECK(c->target==m->target); CHECK(c->clock==m->clock); CHECK(c->seen==m->seen);
    CHECK(c->late==m->late); CHECK(c->presented==m->presented); CHECK(c->dropped==m->dropped);
    CHECK(c->last_pts==m->last_pts); CHECK(c->have_pts==m->have_pts);
    for(i=0;i<c->count;++i) {
        if(i) CHECK(c->frames[i-1].pts<=c->frames[i].pts);
        for(j=0;j<m->count;++j) if(c->frames[i].token==m->items[j].f.token) break;
        CHECK(j<m->count); CHECK(!memcmp(&c->frames[i],&m->items[j].f,sizeof(Frame)));
    }
    for(i=c->count;i<CAP;++i) {
        Frame zero={0}; CHECK(!memcmp(&c->frames[i],&zero,sizeof(zero)));
    }
}
static void push(Context *c,Model *m,Frame f) {
    Context old=*c; int want=model_push(m,f), got=video_sync_push(c,&f);
    CHECK(got==want); if(got!=1) CHECK(!memcmp(&old,c,sizeof(old))); state(c,m);
}
static int select_frame(Context *c,Model *m,Clock clock) {
    struct { uint64_t a; Result r; uint64_t b; } output;
    Result expected; Context old=*c; int want,got;
    memset(&output,0x73,sizeof(output)); memset(&expected,0x73,sizeof(expected));
    want=model_select(m,clock,&expected); got=video_sync_select(c,&clock,&output.r);
    CHECK(got==want); CHECK(!memcmp(&expected,&output.r,sizeof(expected)));
    CHECK(output.a==0x7373737373737373ULL && output.b==output.a);
    if(got==-1) CHECK(!memcmp(&old,c,sizeof(old))); state(c,m); return got;
}
static void drain(Context *c,Model *m) {
    Frame got,want; int result; Context old=*c;
    memset(&got,0x51,sizeof(got)); want=got;
    if(m->count) want=remove_first(m);
    result=video_sync_drain(c,&got); CHECK(result==(old.count?1:0)); CHECK(!memcmp(&got,&want,sizeof(got)));
    if(!result) CHECK(!memcmp(&old,c,sizeof(old))); state(c,m);
}
static void epoch(Context *c,Model *m,uint64_t e,int64_t target) {
    Context old=*c; int want=!m->count && e && e>m->epoch && target>=0;
    CHECK(video_sync_epoch(c,e,target)==want);
    if(want) { m->epoch=e; m->target=target; m->clock=0; m->seen=0; m->presented=m->dropped=0; m->last_pts=0; m->have_pts=0; }
    else CHECK(!memcmp(&old,c,sizeof(old))); state(c,m);
}
static void start(Guarded *g,Model *m,uint64_t late,int64_t target) {
    memset(g,0xa5,sizeof(*g)); memset(m,0,sizeof(*m));
    CHECK(video_sync_init(&g->ctx,late)==1); m->late=late; state(&g->ctx,m);
    epoch(&g->ctx,m,1,target); guards(g);
}
static void scripted(void) {
    Guarded g; Model m; Context *c=&g.ctx; Clock k={1,0,0,0}; unsigned i;
    start(&g,&m,50000000,100000000);
    /* Preroll, stable equal PTS, out-of-order decoder completion and early wait. */
    push(c,&m,(Frame){200000000,40000000,1,1});
    push(c,&m,(Frame){-100000000,200000000,2,1});
    push(c,&m,(Frame){100000000,40000000,3,1});
    push(c,&m,(Frame){100000000,40000000,4,1});
    CHECK(select_frame(c,&m,k)==DROP); CHECK(select_frame(c,&m,k)==WAIT);
    k.media=100000000; k.state=1; CHECK(select_frame(c,&m,k)==HOLD);
    k.state=2; CHECK(select_frame(c,&m,k)==HOLD);
    k.state=3; CHECK(select_frame(c,&m,k)==PRESENT); CHECK(select_frame(c,&m,k)==PRESENT);
    CHECK(select_frame(c,&m,k)==PRESENT); CHECK(select_frame(c,&m,k)==EMPTY);
    /* Late threshold is strict; a future successor cannot cause a black gap. */
    start(&g,&m,50000000,100000000); k=(Clock){1,100000000,0,0};
    push(c,&m,(Frame){100000000,10000000,5,1});
    push(c,&m,(Frame){160000000,10000000,6,1});
    k.state=0; k.media=160000000; CHECK(select_frame(c,&m,k)==PRESENT);
    push(c,&m,(Frame){100000000,10000000,7,1});
    k.media=160000001; CHECK(select_frame(c,&m,k)==DROP);
    CHECK(select_frame(c,&m,k)==PRESENT);
    push(c,&m,(Frame){200000000,1000000,8,1});
    push(c,&m,(Frame){1000000000,1000000,9,1});
    k.media=900000000; CHECK(select_frame(c,&m,k)==PRESENT);
    CHECK(select_frame(c,&m,k)==WAIT);
    push(c,&m,(Frame){150000000,1000000000,11,1});
    CHECK(select_frame(c,&m,k)==DROP); /* late decoder completion cannot reverse */
    epoch(c,&m,2,0); /* refusal while caller-owned surfaces are queued */
    drain(c,&m); epoch(c,&m,2,0);
    push(c,&m,(Frame){0,1000000,10,1}); CHECK(select_frame(c,&m,k)==-1);
    k.epoch=2; k.media=0; k.state=0;
    /* Full queue, duplicate token even when full, and unsigned epoch rollover. */
    for(i=0;i<CAP;++i) push(c,&m,(Frame){(int64_t)(CAP-i)*1000000,1000000,100+i,2});
    push(c,&m,(Frame){0,1,100,2}); push(c,&m,(Frame){0,1,999,2});
    while(m.count) drain(c,&m);
    epoch(c,&m,UINT64_MAX,0); epoch(c,&m,0,0); epoch(c,&m,1,0);
    guards(&g);
    /* Representable endpoint extremes and subtraction beyond signed range. */
    start(&g,&m,0,0); k=(Clock){1,INT64_MAX,0,0};
    push(c,&m,(Frame){INT64_MIN,1,1,1});
    push(c,&m,(Frame){INT64_MAX-1,1,2,1});
    push(c,&m,(Frame){INT64_MAX,1,3,1});
    push(c,&m,(Frame){0,INT64_MIN,4,1});
    CHECK(select_frame(c,&m,k)==DROP); CHECK(select_frame(c,&m,k)==PRESENT);
    k.media=0; CHECK(select_frame(c,&m,k)==-1);
    epoch(c,&m,2,0); k=(Clock){2,1000000000,0,0};
    push(c,&m,(Frame){0,1,1,2});
    CHECK(select_frame(c,&m,k)==PRESENT); /* last frame survives arbitrary lateness */
    epoch(c,&m,3,100000000); k=(Clock){3,100000000,0,0};
    push(c,&m,(Frame){50000000,100000000,1,3});
    CHECK(select_frame(c,&m,k)==PRESENT); /* interval containing seek target */
    /* Saturating diagnostics; no wrap after a long-running session. */
    epoch(c,&m,4,0); c->presented=m.presented=UINT64_MAX;
    c->dropped=m.dropped=UINT64_MAX;
    push(c,&m,(Frame){-2,1,1,4}); push(c,&m,(Frame){0,1,2,4});
    k=(Clock){4,0,0,0}; CHECK(select_frame(c,&m,k)==DROP); CHECK(select_frame(c,&m,k)==PRESENT);
    guards(&g);
}
static void random_operations(void) {
    Guarded g; Model m; Context *c=&g.ctx; uint64_t token=1; unsigned i;
    start(&g,&m,17000000,0);
    for(i=0;i<500000;++i) {
        uint64_t r=random64(); ++operations;
        switch(r%8) {
        case 0: case 1: case 2: case 3: {
            Frame f; f.pts=m.clock+(int64_t)(random64()%400000001)-200000000;
            f.duration=1+(int64_t)(random64()%100000000); f.token=token++; f.epoch=m.epoch;
            switch((r>>8)%16) {
            case 0: f.pts=INT64_MIN; break;
            case 1: f.pts=INT64_MAX-(int64_t)(r&63); break;
            case 2: f.duration=0; break;
            case 3: f.duration=-1; break;
            case 4: f.epoch=m.epoch-1; break;
            case 5: f.token=m.count?m.items[0].f.token:0; break;
            }
            push(c,&m,f); break;
        }
        case 4: case 5: {
            Clock k={m.epoch,m.clock+(int64_t)(random64()%60000000),(uint32_t)((r>>11)%4),0};
            switch((r>>8)%16) {
            case 0: k.epoch=m.epoch-1; break;
            case 1: k.media=m.clock-1; break;
            case 2: k.state=4; break;
            case 3: k.reserved=1; break;
            }
            select_frame(c,&m,k); break;
        }
        case 6: drain(c,&m); break;
        case 7:
            if((r>>16)%8==0) { while(m.count) drain(c,&m); epoch(c,&m,m.epoch+1,random64()%1000000000); }
            else epoch(c,&m,m.epoch+1,0);
            break;
        }
        if((i&1023)==0) guards(&g);
    }
    while(m.count) drain(c,&m); guards(&g);
}
static int64_t media_pts(uint64_t frame) {
    const unsigned prefix[]={0,1,4,6};
    return (int64_t)(((frame/4)*8+prefix[frame%4])*1001000000ULL/120);
}
static void media_simulation(void) {
    /* 44.1/48/192 kHz audio masters; 59.94fps VFR frames, bounded lookahead,
       one second stalled output, pause and step. Caller retains displayed frame. */
    const unsigned rates[]={44100,48000,192000}; unsigned rate_index;
    for(rate_index=0;rate_index<3;++rate_index) {
        Guarded g; Model m; Context *c=&g.ctx; uint64_t next=0, audio=0, old_audio=0;
        unsigned t; uint64_t late_drops=0, displayed=0;
        start(&g,&m,50000000,0);
        for(t=0;t<12000;++t) {
            int64_t now=video_sync_sample_ns(audio,rates[rate_index]);
            Clock k={1,now,0,0}; int a;
            while(m.count<16 && next<600) {
                int64_t pts=media_pts(next), end=media_pts(next+1);
                push(c,&m,(Frame){pts,end-pts,next+1,1}); ++next;
            }
            if(t>=1000 && t<2000) k.state=2; /* device starved: audible clock freezes */
            if(t>=3000 && t<3500) k.state=1;
            if(t==3100 || t==3200) k.state=3;
            if(t==6000) { /* render worker missed 250ms, audio kept playing */
                audio+=rates[rate_index]/4; now=video_sync_sample_ns(audio,rates[rate_index]); k.media=now;
            }
            a=select_frame(c,&m,k); if(a==PRESENT) ++displayed; if(a==DROP) ++late_drops;
            if(k.state==1 || k.state==2) CHECK(a==HOLD);
            else if(k.state==3) CHECK(a==PRESENT);
            if(k.state==1 || k.state==2 || k.state==3) CHECK(audio==old_audio);
            else audio+=rates[rate_index]/1000;
            old_audio=audio;
        }
        while(m.count) drain(c,&m);
        CHECK(next==600 && displayed>500 && late_drops>0 && displayed+late_drops==600);
        guards(&g);
    }
}
static void protected_context(void) {
    unsigned char *area; size_t page; Context *c; Model m={0}; unsigned i;
#ifdef _WIN32
    SYSTEM_INFO info; DWORD previous; GetSystemInfo(&info); page=info.dwPageSize;
    area=(unsigned char*)VirtualAlloc(0,page*3,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE); CHECK(area!=0);
    CHECK(VirtualProtect(area,page,PAGE_NOACCESS,&previous));
    CHECK(VirtualProtect(area+page*2,page,PAGE_NOACCESS,&previous));
#else
    page=(size_t)sysconf(_SC_PAGESIZE);
    area=mmap(0,page*3,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0); CHECK(area!=MAP_FAILED);
    CHECK(!mprotect(area,page,PROT_NONE)); CHECK(!mprotect(area+page*2,page,PROT_NONE));
#endif
    c=(Context*)(area+page*2-sizeof(*c)); CHECK(sizeof(*c)==BYTES);
    CHECK(video_sync_init(c,0)); epoch(c,&m,1,0);
    for(i=0;i<CAP;++i) push(c,&m,(Frame){CAP-i,1,i+1,1});
    push(c,&m,(Frame){0,1,100,1}); while(m.count) drain(c,&m);
    /* Invalid metadata never indexes beyond the fixed queue. */
    c->count=UINT32_MAX;
    { Frame f={0,1,1,1}, o; Result r; Clock k={1,0,0,0}; Context old=*c;
      memset(&o,0x7b,sizeof(o)); memset(&r,0x7b,sizeof(r));
      CHECK(video_sync_push(c,&f)==-1); CHECK(video_sync_drain(c,&o)==-1);
      CHECK(video_sync_select(c,&k,&r)==-1); CHECK(!video_sync_epoch(c,2,0));
      CHECK(!memcmp(c,&old,sizeof(old)));
      for(i=0;i<sizeof(o);++i) CHECK(((unsigned char*)&o)[i]==0x7b);
      for(i=0;i<sizeof(r);++i) CHECK(((unsigned char*)&r)[i]==0x7b);
    }
    { Context old=*c; CHECK(!video_sync_init(c,UINT64_MAX)); CHECK(!memcmp(c,&old,sizeof(old))); }
#ifdef _WIN32
    CHECK(VirtualFree(area,0,MEM_RELEASE));
#else
    CHECK(!munmap(area,page*3));
#endif
}
static uint64_t sample_vectors(const char *path) {
    FILE *f=fopen(path,"rb"); uint64_t n=0;
    struct { uint64_t sample; uint32_t rate, padding; int64_t ns; } v;
    CHECK(f!=0); CHECK(sizeof(v)==24);
    while(fread(&v,sizeof(v),1,f)==1) { CHECK(video_sync_sample_ns(v.sample,v.rate)==v.ns); ++n; }
    CHECK(feof(f)); fclose(f); CHECK(n>10000); return n;
}
int main(int argc,char **argv) {
    uint64_t vectors;
    CHECK(argc==2); CHECK(sizeof(Context)==BYTES); CHECK(sizeof(Result)==40);
    scripted(); random_operations(); media_simulation(); protected_context(); vectors=sample_vectors(argv[1]);
    printf("{\"result\":\"passed\",\"checks\":%llu,\"random_operations\":%llu,\"audio_clock_vectors\":%llu,\"simulated_av_sessions\":3,\"video_frames_per_session\":600,\"context_bytes\":%u,\"queue_capacity\":%u}\n",
        (unsigned long long)checks,(unsigned long long)operations,(unsigned long long)vectors,BYTES,CAP);
    return 0;
}
