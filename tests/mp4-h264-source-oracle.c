/* Original CPU-only MP4/H264 callback contract oracle. MIT. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#define ABI
#else
#define ABI __attribute__((ms_abi))
#endif
typedef struct{unsigned char a[64],ctx[8192],b[64];} MP4;
typedef struct{unsigned char a[64],ctx[16384],b[64];} H264;
typedef struct{uint32_t choice,reserved;volatile uint32_t*cancel;uint64_t epoch;} Options;
extern int ABI video_mp4_open(void*,const void*,uint64_t,const void*);
extern int ABI video_mp4_next(void*,void*);
extern void ABI video_mp4_close(void*);
extern int ABI video_mp4_h264_reset(void*,void*);
extern int ABI video_mp4_h264_next(void*,void*,void*);
extern int ABI h264_packet_next(void*,void*);
extern void ABI h264_close(void*);
static uint64_t checks;
#define CHECK(x) do{++checks;if(!(x)){fprintf(stderr,"mp4-source line%d\n",__LINE__);exit(2);}}while(0)
static uint64_t u64(const void*p){uint64_t x;memcpy(&x,p,8);return x;}
static uint32_t u32(const void*p){uint32_t x;memcpy(&x,p,4);return x;}
static void guard(const void*a,const void*b){unsigned i;for(i=0;i<64;++i)CHECK(((const unsigned char*)a)[i]==0xa5 && ((const unsigned char*)b)[i]==0xa5);}
int main(int argc,char**argv){
    MP4 a,b;H264 x,y;Options options;volatile uint32_t cancel=0;unsigned char pa[80],pb[80],previous[80],*data;FILE*f;long size;int ra,rb;unsigned pictures=0,yields=0,i;
    CHECK(argc==2);f=fopen(argv[1],"rb");CHECK(f && !fseek(f,0,SEEK_END));size=ftell(f);CHECK(size>0 && !fseek(f,0,SEEK_SET));data=malloc(size);CHECK(data && fread(data,1,size,f)==(size_t)size);fclose(f);
    memset(&a,0xa5,sizeof(a));memset(a.ctx,0,8192);memset(&b,0xa5,sizeof(b));memset(b.ctx,0,8192);memset(&x,0xa5,sizeof(x));memset(x.ctx,0,16384);memset(&y,0xa5,sizeof(y));memset(y.ctx,0,16384);
    options=(Options){0,0,&cancel,1};CHECK(video_mp4_open(a.ctx,data,size,&options) && video_mp4_open(b.ctx,data,size,&options));CHECK(video_mp4_h264_reset(a.ctx,x.ctx) && video_mp4_h264_reset(b.ctx,y.ctx));
    for(;;){
        do{ra=video_mp4_h264_next(a.ctx,x.ctx,pa);if(ra==2)++yields;}while(ra==2);
        do{rb=video_mp4_next(b.ctx,pb);}while(rb==1 && (u32(pb+48)&8));
        if(rb==1)rb=h264_packet_next(y.ctx,pb);
        CHECK(ra==rb);if(!ra)break;CHECK(ra==1 && !memcmp(pa,pb,80) && u64(pa+40)==2);
        CHECK(u64(x.ctx+48)==u64(y.ctx+48) && u64(x.ctx+14832)==u64(y.ctx+14832) && u32(x.ctx+14860)==u32(y.ctx+14860));++pictures;
        guard(a.a,a.b);guard(b.a,b.b);guard(x.a,x.b);guard(y.a,y.b);
    }
    CHECK(u64(x.ctx+48)==pictures);CHECK(video_mp4_h264_reset(a.ctx,x.ctx) && u64(a.ctx+32)==3 && !u64(x.ctx+48));
    memset(pa,0xa7,80);memcpy(previous,pa,80);cancel=1;CHECK(video_mp4_h264_next(a.ctx,x.ctx,pa)==-1 && !memcmp(pa,previous,80) && u32(a.ctx+28)==61);cancel=0;
    CHECK(video_mp4_h264_next(a.ctx,x.ctx,pa)==-1 && !video_mp4_h264_reset(a.ctx,x.ctx));
    h264_close(x.ctx);h264_close(x.ctx);h264_close(y.ctx);video_mp4_close(a.ctx);video_mp4_close(a.ctx);video_mp4_close(b.ctx);
    guard(a.a,a.b);guard(b.a,b.b);guard(x.a,x.b);guard(y.a,y.b);
    for(i=0;i<8192;++i)CHECK(!a.ctx[i] && !b.ctx[i]);for(i=0;i<16384;++i)CHECK(!x.ctx[i] && !y.ctx[i]);free(data);
    printf("{\"result\":\"passed\",\"checks\":%llu,\"pictures\":%u,\"empty_yields\":%u}\n",(unsigned long long)checks,pictures,yields);return 0;
}
