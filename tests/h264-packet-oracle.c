/* Original packet/timestamp and protected-input oracle. Test-only C. MIT. */
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
typedef struct { unsigned char before[64],ctx[16384],after[64]; } Parser;
typedef struct { const void *data; uint64_t bytes; int64_t dts,pts; uint64_t duration,epoch; } Packet;
typedef struct { const void *picture,*matrix,*bits; uint32_t bytes,pad; const void *slices; uint32_t count,pad2; } Frame;
extern int ABI h264_packet_open(void*,const void*,uint64_t,const volatile uint32_t*);
extern int ABI h264_packet_next(void*,const Packet*);
extern void ABI h264_close(void*);
#ifdef _WIN32
extern HRESULT win_video_open_pool(void*,UINT,UINT,UINT);
extern HRESULT win_video_decode(void*,const void*);
extern HRESULT win_video_readback(void*,void*,uint64_t);
extern void win_video_close(void*);
#endif
static uint64_t checks,frames,opens,image_bytes;
static uint64_t fingerprint=1469598103934665603ULL;
static uint32_t random_state=0x4c414d50;
#define CHECK(x) do { ++checks; if(!(x)){fprintf(stderr,"h264-packet line%d frame%llu open%llu\n",__LINE__,(unsigned long long)frames,(unsigned long long)opens);exit(2);} }while(0)
static uint32_t u32(const void*p){uint32_t n;memcpy(&n,p,4);return n;}
static uint64_t u64(const void*p){uint64_t n;memcpy(&n,p,8);return n;}
static unsigned char *file(const char *name,size_t *bytes){FILE*f=fopen(name,"rb");long n;unsigned char*p;CHECK(f);CHECK(!fseek(f,0,SEEK_END));n=ftell(f);CHECK(n>=0 && n<=536870912);CHECK(!fseek(f,0,SEEK_SET));p=malloc((size_t)n+1);CHECK(p);CHECK(fread(p,1,n,f)==(size_t)n);fclose(f);*bytes=n;return p;}
static void guard(Parser *p){unsigned i;for(i=0;i<64;++i)CHECK(p->before[i]==0xa5 && p->after[i]==0xa5);}
static void fresh(Parser *p){memset(p,0xa5,sizeof(*p));memset(p->ctx,0,sizeof(p->ctx));++opens;}
static void close_parser(Parser *p){unsigned i;guard(p);h264_close(p->ctx);h264_close(p->ctx);guard(p);for(i=0;i<16384;++i)CHECK(!p->ctx[i]);}
static void validate(Parser *p,Packet *packet){
    Frame f;memcpy(&f,p->ctx+328,48);CHECK(f.picture==p->ctx+384 && f.matrix==p->ctx+1424 && f.slices==p->ctx+1648);
    CHECK(f.bytes && f.bytes<=16777216 && !(f.bytes&127) && f.count && f.count<=256);
    CHECK(u64(p->ctx+14880)==(uint64_t)packet->dts && u64(p->ctx+14888)==(uint64_t)packet->pts);
    CHECK(u64(p->ctx+14896)==packet->duration && u64(p->ctx+14904)==packet->epoch);guard(p);
}
static void serialize(FILE *f,Parser*p){Frame d;memcpy(&d,p->ctx+328,48);CHECK(fwrite(&d.bytes,4,1,f)==1 && fwrite(&d.count,4,1,f)==1);CHECK(fwrite(d.picture,1040,1,f)==1 && fwrite(d.matrix,224,1,f)==1);CHECK(fwrite(d.slices,d.count*10,1,f)==1 && fwrite(d.bits,d.bytes,1,f)==1);}
static uint32_t rnd(void){random_state^=random_state<<13;random_state^=random_state>>17;random_state^=random_state<<5;return random_state;}
static void hash_bytes(const unsigned char*p,size_t size){size_t i;for(i=0;i<size;++i){fingerprint^=p[i];fingerprint*=1099511628211ULL;}}
static void guarded(const unsigned char *cfg,size_t cfg_size,Packet first){
    Parser p;size_t page,total;unsigned char*area,*end;unsigned i;volatile uint32_t cancel=0;
#ifdef _WIN32
    SYSTEM_INFO info;DWORD old;GetSystemInfo(&info);page=info.dwPageSize;
    total=((first.bytes+cfg_size+page-1)/page+2)*page;area=VirtualAlloc(0,total,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);CHECK(area);
    CHECK(VirtualProtect(area,page,PAGE_NOACCESS,&old) && VirtualProtect(area+total-page,page,PAGE_NOACCESS,&old));
#else
    page=sysconf(_SC_PAGESIZE);total=((first.bytes+cfg_size+page-1)/page+2)*page;area=mmap(0,total,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);CHECK(area!=MAP_FAILED);CHECK(!mprotect(area,page,PROT_NONE) && !mprotect(area+total-page,page,PROT_NONE));
#endif
    end=area+total-page;
    for(i=0;i<=cfg_size;++i){int r;memcpy(end-i,cfg,i);hash_bytes(end-i,i);fresh(&p);r=h264_packet_open(p.ctx,end-i,i,0);CHECK(r==0 || r==1);if(r)CHECK(u32(p.ctx+60)==3);hash_bytes((unsigned char*)&r,4);hash_bytes(p.ctx+56,4);close_parser(&p);}
    for(i=0;i<3073;++i){size_t n;unsigned j;Packet q=first;int r;
        n=i<=1024?(size_t)first.bytes*i/1024:rnd()%((size_t)first.bytes+1);memcpy(end-n,first.data,n);
        if(i>1024)for(j=0;j<4 && n;++j){size_t index=rnd()%n;unsigned char mask=(unsigned char)(1+rnd()%255);end[-1-(ptrdiff_t)index]^=mask;}
        hash_bytes(end-n,n);
        q.data=end-n;q.bytes=n;fresh(&p);CHECK(h264_packet_open(p.ctx,cfg,cfg_size,&cancel));r=h264_packet_next(p.ctx,&q);CHECK(r==1 || r==-1);
        hash_bytes((unsigned char*)&r,4);hash_bytes(p.ctx+56,4);
        if(r==1)validate(&p,&q);else CHECK(h264_packet_next(p.ctx,&first)==-1);close_parser(&p);
    }
    fresh(&p);CHECK(h264_packet_open(p.ctx,cfg,cfg_size,&cancel));cancel=1;CHECK(h264_packet_next(p.ctx,&first)==-1 && u32(p.ctx+56)==61);close_parser(&p);
#ifdef _WIN32
    CHECK(VirtualFree(area,0,MEM_RELEASE));
#else
    CHECK(!munmap(area,total));
#endif
}
int main(int argc,char**argv){
    Parser p;size_t bytes,pos,config_size;unsigned char *data;const unsigned char*cfg;uint32_t n,i;FILE*out=0,*reference=0;int do_guard,negative,rejected=0;
#ifdef _WIN32
    unsigned char gpu[1024]={0};unsigned char *pixels=0,*expected=0;size_t capacity=0,visible=0;
#endif
    CHECK(argc==3 || argc==4);CHECK(sizeof(Packet)==48);data=file(argv[1],&bytes);
    if(!strcmp(argv[2],"--reject-config")){fresh(&p);CHECK(!h264_packet_open(p.ctx,data,bytes,0));close_parser(&p);free(data);puts("{\"result\":\"rejected-config\"}");return 0;}
    negative=!strcmp(argv[2],"--reject-packet");CHECK(bytes>=16 && u32(data)==0x31415048);
    config_size=u32(data+4);n=u32(data+8);CHECK(n && n<=4096 && config_size<=bytes-16);cfg=data+16;pos=16+config_size;do_guard=!strcmp(argv[2],"--guard");
    fresh(&p);CHECK(h264_packet_open(p.ctx,cfg,config_size,0));CHECK(!h264_packet_open(p.ctx,cfg,config_size,0));
    if(!do_guard && !negative){out=fopen(argv[2],"wb");CHECK(out);{uint32_t header[]={0x31305657,u32(p.ctx+136),u32(p.ctx+140),n};CHECK(fwrite(header,16,1,out)==1);}}
#ifdef _WIN32
    if(argc==4){unsigned pool=max(1,u32(p.ctx+14828))+2;reference=fopen(argv[3],"rb");CHECK(reference);CHECK(win_video_open_pool(gpu,u32(p.ctx+136),u32(p.ctx+140),pool)==S_OK);
        capacity=(size_t)u32(p.ctx+136)*u32(p.ctx+140)*3/2;visible=(size_t)u32(p.ctx+144)*u32(p.ctx+148)*3/2;pixels=malloc(capacity);expected=malloc(visible);CHECK(pixels && expected);}
#else
    CHECK(argc==3);
#endif
    for(i=0;i<n;++i){Packet q;uint32_t size,rank;CHECK(bytes-pos>=40);size=u32(data+pos);rank=u32(data+pos+4);memcpy(&q.dts,data+pos+8,32);pos+=40;CHECK(size && size<=bytes-pos && rank<n);q.data=data+pos;q.bytes=size;pos+=size;
        if(do_guard){guarded(cfg,config_size,q);break;}
        {uint64_t saved[4];int result;memcpy(saved,p.ctx+14880,32);result=h264_packet_next(p.ctx,&q);
         if(negative && result==-1){CHECK(!memcmp(saved,p.ctx+14880,32));CHECK(h264_packet_next(p.ctx,&q)==-1);rejected=1;break;}CHECK(result==1);}
        validate(&p,&q);if(out)serialize(out,&p);++frames;
#ifdef _WIN32
        if(reference){HRESULT hr;uint64_t deadline=GetTickCount64()+5000;unsigned y,x,w=u32(p.ctx+136),h=u32(p.ctx+140),vw=u32(p.ctx+144),vh=u32(p.ctx+148),left=u32(p.ctx+152),top=u32(p.ctx+156);
            do{hr=win_video_decode(gpu,p.ctx+328);if(hr==E_PENDING){CHECK(GetTickCount64()<deadline);Sleep(1);}}while(hr==E_PENDING);CHECK(hr==S_OK);
            deadline=GetTickCount64()+5000;do{hr=win_video_readback(gpu,pixels,capacity);if(hr==E_PENDING){CHECK(GetTickCount64()<deadline);Sleep(1);}}while(hr==E_PENDING);CHECK(hr==S_OK);
            CHECK(!fseek(reference,(long)(rank*visible),SEEK_SET));CHECK(fread(expected,visible,1,reference)==1);
            for(y=0;y<vh;++y)for(x=0;x<vw;++x)CHECK(pixels[(top+y)*w+left+x]==expected[y*vw+x]);
            for(y=0;y<vh/2;++y)for(x=0;x<vw;++x)CHECK(pixels[w*h+(top/2+y)*w+left+x]==expected[vw*vh+y*vw+x]);image_bytes+=visible;
        }
#endif
    }
    CHECK(negative?rejected:(do_guard || pos==bytes));if(out)fclose(out);
#ifdef _WIN32
    if(reference){fclose(reference);win_video_close(gpu);free(pixels);free(expected);}
#endif
    close_parser(&p);free(data);printf("{\"result\":\"passed\",\"checks\":%llu,\"opens\":%llu,\"frames\":%llu,\"image_bytes\":%llu,\"mutation_fingerprint\":\"%016llx\"}\n",(unsigned long long)checks,(unsigned long long)opens,(unsigned long long)frames,(unsigned long long)image_bytes,(unsigned long long)fingerprint);return 0;
}
