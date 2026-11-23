/* Original CPU-only submission clock model and concurrent-reader checks. MIT. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#define ABI
#else
#include <pthread.h>
#include <stdatomic.h>
#define ABI __attribute__((ms_abi))
#endif
typedef struct{uint64_t epoch,base;uint32_t rate,mode;uint64_t reserved;} Config;
typedef struct{uint64_t epoch;int64_t ns;uint32_t state,reserved;uint64_t frames;uint32_t rate,reserved2;} Snapshot;
typedef struct{unsigned char a[64],ctx[1664],b[64];} Clock;
extern int ABI audio_clock_begin(void*,const void*);
extern int ABI audio_clock_can_submit(void*,uint64_t,uint64_t);
extern int ABI audio_clock_submit(void*,uint64_t,uint64_t);
extern int ABI audio_clock_observe(void*,uint64_t,unsigned);
extern int ABI audio_clock_publish(void*,uint64_t,unsigned);
extern int ABI audio_clock_status(void*,unsigned);
extern int ABI audio_clock_read(void*,void*);
static uint64_t checks,hash=1469598103934665603ULL;
#define CHECK(x) do{++checks;if(!(x)){fprintf(stderr,"audio-clock line%d checks%llu\n",__LINE__,(unsigned long long)checks);exit(2);}}while(0)
static uint64_t u64(const void*p){uint64_t x;memcpy(&x,p,8);return x;}
static void put64(void*p,uint64_t x){memcpy(p,&x,8);}
static void fresh(Clock*c){memset(c,0xa5,sizeof(*c));memset(c->ctx,0,1664);}
static void guards(Clock*c){unsigned i;for(i=0;i<64;++i)CHECK(c->a[i]==0xa5 && c->b[i]==0xa5);}
static void fingerprint(const void*p,size_t n){size_t i;for(i=0;i<n;++i){hash^=((const unsigned char*)p)[i];hash*=1099511628211ULL;}}
static uint64_t ns(uint64_t frames,uint32_t rate){uint64_t whole=frames/rate,rem=frames%rate;CHECK(whole<=INT64_MAX/1000000000);return whole*1000000000+rem*1000000000/rate;}
static void snapshot(Clock*c,uint64_t epoch,uint64_t frames,unsigned rate,unsigned state){Snapshot s;CHECK(audio_clock_read(c->ctx,&s));if(s.epoch!=epoch || s.frames!=frames || s.rate!=rate || s.state!=state)fprintf(stderr,"actual %llu %llu %u %u expected %llu %llu %u %u\n",(unsigned long long)s.epoch,(unsigned long long)s.frames,s.rate,s.state,(unsigned long long)epoch,(unsigned long long)frames,rate,state);CHECK(s.epoch==epoch && s.frames==frames && s.rate==rate && s.ns==(int64_t)ns(frames,rate) && s.state==state && !s.reserved && !s.reserved2);fingerprint(&s,40);guards(c);}
typedef struct{uint64_t start,real;} Interval;
static Interval plan[200000];static uint32_t rng=0x434c4f43;
static uint32_t rnd(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static void mapped(void){
    Clock c;Config config={1,1234567,44100,0,0};uint64_t total=0,real=0,pos=0;unsigned n=0,i,j;unsigned char before[1664];
    fresh(&c);CHECK(audio_clock_begin(c.ctx,&config));snapshot(&c,1,config.base,44100,2);
    /* One submitted packet: real media prefix, then starvation silence. The
       former read_count-padding formula holds0 here instead of20. */
    CHECK(audio_clock_submit(c.ctx,100,60));CHECK(audio_clock_observe(c.ctx,20,0));snapshot(&c,1,config.base+20,44100,0);
    CHECK(audio_clock_observe(c.ctx,60,0));snapshot(&c,1,config.base+60,44100,2);
    CHECK(audio_clock_observe(c.ctx,90,0));snapshot(&c,1,config.base+60,44100,2);
    CHECK(audio_clock_submit(c.ctx,100,80));CHECK(audio_clock_observe(c.ctx,125,1));snapshot(&c,1,config.base+85,44100,1);
    memcpy(before,c.ctx,1664);CHECK(!audio_clock_observe(c.ctx,124,0) && !memcmp(before,c.ctx,1664));CHECK(!audio_clock_status(c.ctx,4) && !memcmp(before,c.ctx,1664));
    CHECK(audio_clock_observe(c.ctx,200,4));snapshot(&c,1,config.base+140,44100,4);
    memcpy(before,c.ctx,1664);CHECK(!audio_clock_submit(c.ctx,1,1) && !memcmp(before,c.ctx,1664));CHECK(!audio_clock_observe(c.ctx,200,0) && !memcmp(before,c.ctx,1664));
    config.epoch=2;CHECK(audio_clock_begin(c.ctx,&config));
    for(i=0;i<150000;++i){
        unsigned op=rnd()%4;
        if(op<2){uint64_t size=1+rnd()%512,media=rnd()%(size+1);plan[n++]=(Interval){total,media};CHECK(audio_clock_can_submit(c.ctx,size,media));CHECK(audio_clock_submit(c.ctx,size,media));total+=size;real+=media;}
        else {uint64_t remaining=total-pos;pos+=remaining?rnd()%(remaining+1):0;}
        /* Keep at most a few submitted blocks outstanding, independently of
           implementation coalescing, while exploring every position in gaps. */
        if(total-pos>2000)pos=total;
        {uint64_t expected=config.base;unsigned state=2;for(j=0;j<n;++j){uint64_t consumed=pos>plan[j].start?pos-plan[j].start:0;if(consumed>plan[j].real)consumed=plan[j].real;expected+=consumed;if(pos>=plan[j].start && pos-plan[j].start<plan[j].real)state=0;}
         CHECK(audio_clock_observe(c.ctx,pos,0));snapshot(&c,config.epoch,expected,44100,state);}
        if(pos==total){n=0;config.base+=real;real=0;total=pos=0;++config.epoch;CHECK(audio_clock_begin(c.ctx,&config));}
    }
    guards(&c);
}
static void capacity(void){Clock c;Config q={1,0,48000,0,0};unsigned i;unsigned char old[1664];fresh(&c);CHECK(audio_clock_begin(c.ctx,&q));for(i=0;i<64;++i)CHECK(audio_clock_submit(c.ctx,2,1));memcpy(old,c.ctx,1664);CHECK(!audio_clock_can_submit(c.ctx,2,1) && !audio_clock_submit(c.ctx,2,1) && !memcmp(old,c.ctx,1664));CHECK(audio_clock_submit(c.ctx,100,0));CHECK(audio_clock_observe(c.ctx,128,0));snapshot(&c,1,64,48000,2);CHECK(audio_clock_submit(c.ctx,1,1));CHECK(audio_clock_observe(c.ctx,229,4));snapshot(&c,1,65,48000,4);
    q.epoch=2;CHECK(audio_clock_begin(c.ctx,&q));for(i=0;i<10000;++i)CHECK(audio_clock_submit(c.ctx,1,1));CHECK(u64(c.ctx+72)-u64(c.ctx+64)==1);CHECK(audio_clock_observe(c.ctx,10000,4));snapshot(&c,2,10000,48000,4);guards(&c);
}
static void boundaries(void){
    Clock c;Config q={1,0,48000,1,0};Snapshot s,old;unsigned char before[1664];unsigned rates[]={1,3,8000,11025,44100,48000,192000,768000},i;fresh(&c);memset(&s,0xa7,40);old=s;CHECK(!audio_clock_read(c.ctx,&s) && !memcmp(&s,&old,40));
    for(i=0;i<8;++i){uint64_t limit=(uint64_t)INT64_MAX/1000000000*rates[i]+((uint64_t)INT64_MAX%1000000000)*rates[i]/1000000000;q.epoch=i+1;q.rate=rates[i];q.base=limit;CHECK(audio_clock_begin(c.ctx,&q));snapshot(&c,q.epoch,limit,q.rate,2);CHECK(audio_clock_publish(c.ctx,limit,0));snapshot(&c,q.epoch,limit,q.rate,0);memcpy(before,c.ctx,1664);CHECK(!audio_clock_publish(c.ctx,limit+1,0) && !memcmp(before,c.ctx,1664));CHECK(!audio_clock_publish(c.ctx,limit-1,0) && !memcmp(before,c.ctx,1664));CHECK(!audio_clock_publish(c.ctx,limit,3) && !memcmp(before,c.ctx,1664));CHECK(!audio_clock_submit(c.ctx,1,1) && !memcmp(before,c.ctx,1664));}
    memcpy(before,c.ctx,1664);CHECK(!audio_clock_begin(c.ctx,&q) && !memcmp(before,c.ctx,1664));q.epoch++;q.rate=0;CHECK(!audio_clock_begin(c.ctx,&q));q.rate=768001;CHECK(!audio_clock_begin(c.ctx,&q));q.rate=48000;q.base=0;q.reserved=1;CHECK(!audio_clock_begin(c.ctx,&q));q.reserved=0;q.mode=2;CHECK(!audio_clock_begin(c.ctx,&q));q.mode=1;CHECK(audio_clock_begin(c.ctx,&q));
    put64(c.ctx,1);memset(&s,0xa7,40);old=s;CHECK(!audio_clock_read(c.ctx,&s) && !memcmp(&s,&old,40));put64(c.ctx,UINT64_MAX-1);memcpy(before,c.ctx,1664);CHECK(!audio_clock_publish(c.ctx,0,0) && !memcmp(before,c.ctx,1664));q.epoch++;CHECK(!audio_clock_begin(c.ctx,&q) && !memcmp(before,c.ctx,1664));guards(&c);
}
static Clock threaded;static uint64_t reads,retries;
#ifdef _WIN32
static volatile LONG finished;
static void finish_writer(void){InterlockedExchange(&finished,1);}
static int writer_finished(void){return InterlockedCompareExchange(&finished,0,0)!=0;}
#else
static atomic_uint finished;
static void finish_writer(void){atomic_store_explicit(&finished,1,memory_order_release);}
static int writer_finished(void){return atomic_load_explicit(&finished,memory_order_acquire)!=0;}
#endif
#ifdef _WIN32
static DWORD WINAPI writer(void*arg)
#else
static void*writer(void*arg)
#endif
{Config q={1,0,44100,1,0};unsigned i;(void)arg;for(i=0;i<100000;++i){if(i%1000==0){q.epoch=i/1000+1;q.rate=i%2000?48000:44100;if(!audio_clock_begin(threaded.ctx,&q))abort();}if(!audio_clock_publish(threaded.ctx,i%1000,i%9==0?1:0))abort();}finish_writer();return 0;}
static void concurrency(void){Snapshot s,prior={0},old;
#ifdef _WIN32
    HANDLE thread;
#else
    pthread_t thread;
#endif
    fresh(&threaded);finished=0;
#ifdef _WIN32
    thread=CreateThread(0,0,writer,0,0,0);CHECK(thread);
#else
    CHECK(!pthread_create(&thread,0,writer,0));
#endif
    do{memset(&s,0xa7,40);old=s;if(audio_clock_read(threaded.ctx,&s)){CHECK(s.epoch>=prior.epoch && s.rate==(s.epoch%2?44100:48000) && !s.reserved && !s.reserved2);CHECK(s.epoch!=prior.epoch || s.frames>=prior.frames);CHECK(s.ns==(int64_t)ns(s.frames,s.rate) && s.frames<1000 && s.state<=2);prior=s;++reads;}else{CHECK(!memcmp(&s,&old,40));++retries;}}while(!writer_finished());
#ifdef _WIN32
    CHECK(WaitForSingleObject(thread,30000)==WAIT_OBJECT_0);CloseHandle(thread);
#else
    CHECK(!pthread_join(thread,0));
#endif
    CHECK(reads);snapshot(&threaded,100,999,48000,1);guards(&threaded);
}
int main(void){CHECK(sizeof(Config)==32 && sizeof(Snapshot)==40);mapped();capacity();boundaries();concurrency();printf("{\"result\":\"passed\",\"checks\":%llu,\"model_operations\":150000,\"reader_snapshots\":%llu,\"reader_retries\":%llu,\"fingerprint\":\"%016llx\"}\n",(unsigned long long)checks,(unsigned long long)reads,(unsigned long long)retries,(unsigned long long)hash);return 0;}
