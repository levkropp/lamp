/* Original CPU-only output-order/ownership oracle. Synthetic input never reaches a driver. MIT. */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern HRESULT win_video_stream_open(void*,void*,void*);
extern HRESULT win_video_stream_next(void*);
extern void win_video_stream_close(void*);
extern HRESULT win_video_stream_peek(void*);
extern HRESULT win_video_stream_set_source(void*,void*,void*);
typedef struct { uint64_t epoch; int32_t poc; uint32_t discard; } Picture;
static Picture plan[256],expected[256];
static unsigned count,cursor,submitted,selected,checks,decode_calls,select_calls,force_decode_error,force_select_error,parse_error;
static uint32_t cancel;
static unsigned timed_mode,source_calls,source_fault;
static unsigned char gpu[1024],parser[16384];
static struct { unsigned char a[64],state[1536],b[64]; } stream;
#define CHECK(x) do { ++checks; if(!(x)){fprintf(stderr,"stream line%d input%u submitted%u output%u\n",__LINE__,cursor,submitted,selected);exit(1);} }while(0)
static uint32_t u32(const void*p){uint32_t n;memcpy(&n,p,4);return n;}
static uint64_t u64(const void*p){uint64_t n;memcpy(&n,p,8);return n;}
static void put32(void*p,uint32_t n){memcpy(p,&n,4);}
static void put64(void*p,uint64_t n){memcpy(p,&n,8);}
static uint64_t stamp(const Picture*p){uint64_t rank=(unsigned)(p->poc+128);return 500000000+rank*1000000+rank*rank*1000;}
static int hidden(const Picture*p){return timed_mode && p->poc%11==0;}
int h264_next(void *ctx){
    unsigned slot=0;Picture *p;CHECK(ctx==parser);CHECK(cursor==submitted);
    if(parse_error)return -1;
    if(cursor==count)return 0;
    while(slot<32 && (u32(parser+14816)&(1u<<slot)))++slot;
    CHECK(slot<u32(parser+14820));p=plan+cursor;
    put32(parser+12508,slot);put64(parser+14832,p->epoch);put32(parser+14860,p->poc);
    put32(parser+12432,(cursor==0 || p->epoch!=plan[cursor-1].epoch)?5:1);
    put32(parser+14852,p->discard);++cursor;return 1;
}
static int source_next(void*ctx,void*hp,void*out){
    unsigned char*p=out;int r;Picture*picture;CHECK(ctx==&timed_mode && hp==parser);++source_calls;
    if(source_calls%7==1)return 2;
    r=h264_next(hp);if(r!=1)return r;picture=plan+cursor-1;memset(p,0,80);
    put64(p,(uintptr_t)parser);put64(p+8,16);put64(p+16,(cursor-1)*1000000);put64(p+24,stamp(picture));put64(p+32,2000000);put64(p+40,7);
    put32(p+48,hidden(picture)?2:0);put32(p+52,cursor-1);put64(p+56,stamp(picture));put64(p+64,hidden(picture)?0:2000000);put64(p+72,2000000);
    if(source_fault==1)put64(p+40,cursor==1?7:8);
    if(source_fault==2)put64(p+32,0);
    if(source_fault==3)put64(p+56,UINT64_MAX);
    if(source_fault==4)put32(p+48,8);
    if(source_fault==5)put64(p+64,0);
    if(source_fault==6)put64(p+56,cursor==1?500000000:1);
    return 1;
}
HRESULT win_video_decode(void *ctx,const void *desc){
    CHECK(ctx==gpu && desc==parser+328);CHECK(cursor==submitted+1);++decode_calls;
    if(force_decode_error)return E_FAIL;
    if(decode_calls&1)return E_PENDING;
    CHECK(!(u32(parser+14816)&(1u<<u32(parser+12508))));put32(gpu+100,u32(parser+12508));put32(gpu+92,1);++submitted;return S_OK;
}
HRESULT win_video_select(void *ctx,unsigned slot){
    CHECK(ctx==gpu && slot<18);CHECK(u32(parser+14816)&(1u<<slot));++select_calls;
    if(force_select_error)return E_FAIL;
    if(select_calls&1)return E_PENDING;
    put32(gpu+100,slot);return S_OK;
}
static void invariant(void){
    uint32_t mask=0;unsigned i,n=u32(stream.state+32);int last=(int)u32(stream.state+40);
    CHECK(n<=17);if(last>=0)mask|=1u<<last;
    for(i=0;i<n;++i){unsigned slot=u32(stream.state+384+i*64+12);CHECK(slot<18 && !(mask&(1u<<slot)));mask|=1u<<slot;}
    CHECK(mask==u32(parser+14816));
    for(i=0;i<64;++i)CHECK(stream.a[i]==0xa5 && stream.b[i]==0xa5);
}
static void setup(unsigned reorder){
    memset(&stream,0xa5,sizeof(stream));memset(stream.state,0,1536);memset(gpu,0,sizeof(gpu));memset(parser,0,sizeof(parser));
    put32(gpu+72,1);put32(gpu+80,18);put32(parser+14824,reorder);put32(parser+14828,16);put64(parser+64,(uintptr_t)&cancel);
    cursor=submitted=selected=decode_calls=select_calls=force_decode_error=force_select_error=parse_error=cancel=0;
    timed_mode=source_calls=source_fault=0;
    CHECK(win_video_stream_next(stream.state)==E_UNEXPECTED);
    CHECK(win_video_stream_open(stream.state,gpu,parser)==S_OK);
    CHECK(win_video_stream_open(stream.state,gpu,parser)==E_UNEXPECTED);invariant();
}
static void finish(void){
    unsigned i;win_video_stream_close(stream.state);win_video_stream_close(stream.state);CHECK(u32(parser+14816)==0);
    for(i=0;i<1536;++i)CHECK(stream.state[i]==0);
    for(i=0;i<64;++i)CHECK(stream.a[i]==0xa5 && stream.b[i]==0xa5);
}
static void verify(unsigned outputs,unsigned drops){
    HRESULT hr;unsigned spins=0;
    do{
        if(timed_mode){unsigned calls=select_calls;uint64_t prior=u64(stream.state+48);uint32_t last=u32(stream.state+40);
            hr=win_video_stream_peek(stream.state);invariant();CHECK(select_calls==calls && prior==u64(stream.state+48) && last==u32(stream.state+40));if((int32_t)last>=0)CHECK(u32(gpu+100)==last);
            if(hr==E_PENDING)continue;CHECK(hr==S_OK || hr==S_FALSE);
            if(hr==S_OK){CHECK(selected<outputs && u64(stream.state+160)==stamp(expected+selected));
                {unsigned dec=decode_calls,sel=select_calls;CHECK(win_video_stream_peek(stream.state)==S_OK && dec==decode_calls && sel==select_calls);}}
        }
        hr=win_video_stream_next(stream.state);invariant();CHECK(++spins<4096);
        if(hr==E_PENDING)continue;
        CHECK(hr==S_OK || hr==S_FALSE);
        if(hr==S_OK){CHECK(selected<outputs);CHECK(u64(stream.state+72)==expected[selected].epoch);
            CHECK((int32_t)u32(stream.state+80)==expected[selected].poc);CHECK(u32(gpu+100)==u32(stream.state+40));
            if(timed_mode)CHECK(u64(stream.state+112)==stamp(expected+selected) && u64(stream.state+144)==stamp(expected+selected) && u64(stream.state+152)==2000000 && u64(stream.state+136)==7);
            ++selected;}
    }while(hr!=S_FALSE);
    CHECK(selected==outputs && submitted==count && u64(stream.state+64)==drops);
    CHECK(u64(stream.state+48)==outputs && u64(stream.state+56)==count);
    if(timed_mode)CHECK(u64(stream.state+200)==count-outputs);
    CHECK(win_video_stream_next(stream.state)==S_FALSE);invariant();finish();
}
static unsigned random_state=0x4c414d50;
static unsigned rnd(void){random_state^=random_state<<13;random_state^=random_state>>17;random_state^=random_state<<5;return random_state;}
int main(void){
    unsigned r,iteration,i,j;HRESULT hr;
    /* Bounded random permutations of future frames, across all legal reorder bounds. */
    for(r=0;r<=16;++r)for(iteration=0;iteration<32;++iteration){
        count=128;for(i=0;i<count;++i){plan[i].epoch=1;plan[i].poc=(int)i*2-128;plan[i].discard=0;expected[i]=plan[i];}
        for(i=1;i<count;i+=r+1){unsigned n=min(r+1,count-i);for(j=n;j>1;--j){unsigned k=rnd()%j;Picture p=plan[i+j-1];plan[i+j-1]=plan[i+k];plan[i+k]=p;}}
        setup(r);verify(count,0);
    }
    /* Drain before new epochs; optional IDR discard affects queued output only. */
    for(j=0;j<2;++j){
        const int pocs[]={0,6,2,4,0,4,2};count=7;
        for(i=0;i<count;++i){plan[i].epoch=i<4?1:2;plan[i].poc=pocs[i];plan[i].discard=i==4?j:0;}
        expected[0]=(Picture){1,0,0};expected[1]=(Picture){1,2,0};
        if(j){expected[2]=(Picture){2,0,0};expected[3]=(Picture){2,2,0};expected[4]=(Picture){2,4,0};}
        else {expected[2]=(Picture){1,4,0};expected[3]=(Picture){1,6,0};expected[4]=(Picture){2,0,0};expected[5]=(Picture){2,2,0};expected[6]=(Picture){2,4,0};}
        setup(2);verify(j?5:7,j?2:0);
    }
    /* Duplicate POC, late POC, parse/decode/select failures stick without retrying work. */
    for(j=0;j<5;++j){
        count=3;for(i=0;i<count;++i)plan[i]=(Picture){1,(int)i*2,0};setup(j==0?2:0);
        if(j==0)plan[1].poc=0;if(j==1)plan[1].poc=-1;if(j==2)parse_error=1;if(j==3)force_decode_error=1;if(j==4)force_select_error=1;
        do{hr=win_video_stream_next(stream.state);}while(hr==S_OK || hr==E_PENDING);
        CHECK(FAILED(hr));i=decode_calls;CHECK(win_video_stream_next(stream.state)==hr && decode_calls==i);finish();
    }
    setup(2);cancel=1;CHECK(win_video_stream_next(stream.state)==E_ABORT && !decode_calls && !cursor);cancel=0;
    CHECK(win_video_stream_next(stream.state)==E_ABORT);finish();
    /* Peek retains the old selected surface while decoding ahead. Timestamp
       metadata follows reordered pictures, including hidden reference history. */
    for(r=0;r<=16;++r)for(iteration=0;iteration<8;++iteration){
        unsigned shown=0,hidden_count=0;
        count=128;for(i=0;i<count;++i){plan[i]=(Picture){1,(int)i*2-128,0};if(plan[i].poc%11)expected[shown++]=plan[i];else ++hidden_count;}
        for(i=1;i<count;i+=r+1){unsigned n=min(r+1,count-i);for(j=n;j>1;--j){unsigned k=rnd()%j;Picture p=plan[i+j-1];plan[i+j-1]=plan[i+k];plan[i+k]=p;}}
        setup(r);timed_mode=1;CHECK(win_video_stream_set_source(stream.state,source_next,&timed_mode)==S_OK);
        CHECK(win_video_stream_set_source(stream.state,source_next,&timed_mode)==E_INVALIDARG);
        verify(shown,0);(void)hidden_count;
    }
    for(j=1;j<=6;++j){
        count=3;for(i=0;i<count;++i)plan[i]=(Picture){1,(int)i*2+2,0};setup(0);timed_mode=1;source_fault=j;
        CHECK(win_video_stream_set_source(stream.state,source_next,&timed_mode)==S_OK);
        do{hr=win_video_stream_next(stream.state);}while(hr==S_OK || hr==E_PENDING);
        CHECK(FAILED(hr));i=source_calls;CHECK(win_video_stream_next(stream.state)==hr && source_calls==i);finish();
    }
    printf("{\"result\":\"passed\",\"random_permutations\":544,\"timed_permutations\":136,\"epoch_cases\":2,\"sticky_failures\":5,\"timestamp_failures\":6,\"peek_preserves_selection\":true,\"cancel\":true,\"checks\":%u}\n",checks);return 0;
}
