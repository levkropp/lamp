/* Original test-only H.264 frontend serializer and protected-input oracle. MIT. */
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#define ABI
#else
#include <sys/mman.h>
#include <unistd.h>
#define ABI __attribute__((ms_abi))
#endif
enum { HC_CTX=16384, HC_ERROR=56, HC_FRAMES=48, HC_DESC=328 };
typedef struct { unsigned char a[64],ctx[HC_CTX],b[64]; } Guarded;
typedef struct { const void *picture,*matrix,*bits; uint32_t bytes,pad; const void *slices; uint32_t count,pad2; } Frame;
extern int ABI h264_open(void*,const void*,uint64_t,const volatile uint32_t*);
extern int ABI h264_next(void*);
extern void ABI h264_close(void*);
static uint64_t checks,opens,pictures;
static uint64_t mutation_fingerprint=1469598103934665603ULL;
static uint32_t metadata[15];
static uint32_t random_state=0x4c414d50;
#define CHECK(x) do { ++checks; if(!(x)) { fprintf(stderr,"h264-file line%d open%llu\n",__LINE__,(unsigned long long)opens); exit(2); } } while(0)
static uint32_t u32(const void *p) { uint32_t v; memcpy(&v,p,4); return v; }
static uint64_t u64(const void *p) { uint64_t v; memcpy(&v,p,8); return v; }
static uint32_t random32(void) { random_state^=random_state<<13;random_state^=random_state>>17;random_state^=random_state<<5;return random_state; }
static void guards(Guarded *g) { unsigned i; for(i=0;i<64;++i)CHECK(g->a[i]==0xa5 && g->b[i]==0xa5); }
static void frame_check(Guarded *g) {
    Frame f; uint32_t i,end=0; memcpy(&f,g->ctx+HC_DESC,sizeof(f));
    CHECK(f.bytes && f.bytes<=16777216 && !(f.bytes&127)); CHECK(f.count && f.count<=256 && !f.pad && !f.pad2);
    CHECK(f.picture==g->ctx+384 && f.matrix==g->ctx+1424 && f.slices==g->ctx+1648);
    CHECK(f.bits==(const void*)(uintptr_t)u64(g->ctx+24)); CHECK(u64(g->ctx+32)>=f.bytes);
    for(i=0;i<f.count;++i) {
        const unsigned char *s=(const unsigned char*)f.slices+i*10,*p=(const unsigned char*)f.bits;
        uint32_t n=u32(s+4); CHECK(u32(s)==end && n>4 && n<=f.bytes-end); CHECK(s[8]==0 && s[9]==0);
        CHECK(!p[end] && !p[end+1] && p[end+2]==1 && ((p[end+3]&31)==5 || (p[end+3]&31)==1)); end+=n;
    }
    CHECK(end==f.bytes); CHECK(((unsigned char*)f.picture)[4]<=16);
    for(i=16;i<32;++i)CHECK(((unsigned char*)f.picture)[i]==255 || ((((unsigned char*)f.picture)[i]&127)<=16 && (((unsigned char*)f.picture)[i]&127)!=((unsigned char*)f.picture)[4]));
    for(i=0;i<224;++i)CHECK(((unsigned char*)f.matrix)[i]==16);
}
static int scan(const unsigned char *data,size_t bytes,FILE *out,int cancel_after_frame) {
    Guarded g; volatile uint32_t cancel=0; int result=0; uint64_t count=0; unsigned i;
    memset(&g,0xa5,sizeof(g)); memset(g.ctx,0,HC_CTX); ++opens;
    if(h264_open(g.ctx,data,bytes,&cancel)) {
        CHECK(!h264_open(g.ctx,data,bytes,&cancel));
        while((result=h264_next(g.ctx))==1) {
            Frame f; frame_check(&g); guards(&g); ++pictures; ++count;
            CHECK(count<=bytes/4+1); CHECK(u64(g.ctx+HC_FRAMES)==count);
            if(out) {
                memcpy(&f,g.ctx+HC_DESC,sizeof(f));
                if(count==1) { const uint32_t h[]={0x31305657,u32(g.ctx+136),u32(g.ctx+140),0}; CHECK(fwrite(h,sizeof(h),1,out)==1); }
                CHECK(fwrite(&f.bytes,4,1,out)==1 && fwrite(&f.count,4,1,out)==1);
                CHECK(fwrite(f.picture,1040,1,out)==1 && fwrite(f.matrix,224,1,out)==1);
                CHECK(fwrite(f.slices,f.count*10,1,out)==1 && fwrite(f.bits,f.bytes,1,out)==1);
            }
            if(cancel_after_frame)cancel=1;
        }
        CHECK(result==0 || result==-1);
        if(result==0) { CHECK(!u32(g.ctx+HC_ERROR) && count); CHECK(h264_next(g.ctx)==0); }
        else { CHECK(u32(g.ctx+HC_ERROR)); CHECK(h264_next(g.ctx)==-1); }
        if(cancel_after_frame && count)CHECK(result==-1 && u32(g.ctx+HC_ERROR)==61);
        if(out && result==0) { uint32_t n=(uint32_t)count; CHECK(!fseek(out,12,SEEK_SET)); CHECK(fwrite(&n,4,1,out)==1); }
    } else result=-1;
    { const unsigned offsets[]={136,140,144,148,152,156,228,232,236,240,244,248,256,260,252};
      for(i=0;i<15;++i)metadata[i]=u32(g.ctx+offsets[i]); }
    guards(&g); h264_close(g.ctx); h264_close(g.ctx); guards(&g);
    for(i=0;i<HC_CTX;++i)CHECK(!g.ctx[i]); return result;
}
int main(int argc,char **argv) {
    FILE *f,*out=0; unsigned char *data; long length; int result;
    CHECK(argc==3); f=fopen(argv[1],"rb"); CHECK(f!=0); CHECK(!fseek(f,0,SEEK_END)); length=ftell(f);
    CHECK(length>=0 && length<=33554432); CHECK(!fseek(f,0,SEEK_SET));
    data=malloc((size_t)length+1); CHECK(data!=0); CHECK(fread(data,1,length,f)==(size_t)length); fclose(f);
    if(!strcmp(argv[2],"--guard")) {
        unsigned char *area,*end; size_t page,total,initial; unsigned i;
#ifdef _WIN32
        SYSTEM_INFO info; DWORD old; GetSystemInfo(&info); page=info.dwPageSize;
        total=((length+page-1)/page+2)*page;
        area=VirtualAlloc(0,total,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE); CHECK(area!=0);
        CHECK(VirtualProtect(area,page,PAGE_NOACCESS,&old)); CHECK(VirtualProtect(area+total-page,page,PAGE_NOACCESS,&old));
#else
        page=sysconf(_SC_PAGESIZE); total=((length+page-1)/page+2)*page;
        area=mmap(0,total,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0); CHECK(area!=MAP_FAILED);
        CHECK(!mprotect(area,page,PROT_NONE)); CHECK(!mprotect(area+total-page,page,PROT_NONE));
#endif
        end=area+total-page; initial=(size_t)length<512?(size_t)length:512;
        for(i=0;i<=1024;++i) {
            size_t n=i<=initial?i:initial+((size_t)length-initial)*(i-initial)/(1024-initial);
            memcpy(end-n,data,n); scan(end-n,n,0,0);
        }
        for(i=0;i<2048;++i) {
            size_t n=(size_t)length?random32()%((size_t)length+1):0; unsigned j;
            memcpy(end-n,data,n); for(j=0;j<4 && n;++j) {
                size_t index=random32()%n; unsigned char mask=(unsigned char)(1+(random32()%255)); end[-1-index]^=mask;
            }
            for(j=0;j<n;++j) { mutation_fingerprint^=end[-(ptrdiff_t)n+j]; mutation_fingerprint*=1099511628211ULL; }
            scan(end-n,n,0,0);
        }
        scan(data,length,0,1); scan(data,length,0,0);
#ifdef _WIN32
        CHECK(VirtualFree(area,0,MEM_RELEASE));
#else
        CHECK(!munmap(area,total));
#endif
        result=0;
    } else {
        out=fopen(argv[2],"wb"); CHECK(out!=0); result=scan(data,length,out,0); fclose(out);
    }
    printf("{\"result\":\"%s\",\"checks\":%llu,\"opens\":%llu,\"pictures\":%llu,\"mutation_fingerprint\":\"%016llx\",\"metadata\":[",result?"rejected":"passed",(unsigned long long)checks,(unsigned long long)opens,(unsigned long long)pictures,(unsigned long long)mutation_fingerprint);
    { unsigned i; for(i=0;i<15;++i)printf("%s%u",i?",":"",metadata[i]); } puts("]}");
    free(data); return result?1:0;
}
