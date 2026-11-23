/* Original native MP4 packet/timestamp serializer. Test-only C. MIT. */
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
typedef struct { unsigned char before[64],ctx[8192],after[64]; } Context;
typedef struct { uint32_t choice,reserved;const volatile uint32_t *cancel;uint64_t epoch; } Options;
typedef struct { const unsigned char *data;uint64_t size;int64_t dts,pts;uint64_t duration,epoch;uint32_t flags,index;int64_t show_pts;uint64_t show_duration,display_duration; } Packet;
extern int ABI video_mp4_open(void*,const void*,uint64_t,const Options*);
extern int ABI video_mp4_next(void*,Packet*);
extern int ABI video_mp4_rewind(void*,uint64_t);
extern void ABI video_mp4_close(void*);
static uint64_t checks;
static uint64_t guard_opens,guard_packets,guard_fingerprint=1469598103934665603ULL;
#define CHECK(x) do {++checks;if(!(x)){fprintf(stderr,"mp4-video line%d\n",__LINE__);exit(2);}}while(0)
static uint32_t u32(const void*p){uint32_t n;memcpy(&n,p,4);return n;}
static uint64_t u64(const void*p){uint64_t n;memcpy(&n,p,8);return n;}
static void guards(Context*c){unsigned i;for(i=0;i<64;++i)CHECK(c->before[i]==0xa5 && c->after[i]==0xa5);}
static uint64_t hash(uint64_t value,const unsigned char*data,size_t size){size_t i;for(i=0;i<size;++i){value^=data[i];value*=1099511628211ULL;}return value;}
static void fresh(Context*c){memset(c,0xa5,sizeof(*c));memset(c->ctx,0,sizeof(c->ctx));}
static void closed(Context*c){unsigned i;guards(c);video_mp4_close(c->ctx);video_mp4_close(c->ctx);guards(c);for(i=0;i<8192;++i)CHECK(!c->ctx[i]);}

#ifdef LAMP_MEMORY_ORACLE
typedef struct {unsigned char*base;uint64_t bytes;int live;} Allocation;
static Allocation allocations[8];static unsigned operations,fail_at,cancel_at,live;static volatile uint32_t *allocation_cancel;
static int fault(void){++operations;return fail_at && operations==fail_at;}
static void cancelled(void){if(cancel_at && operations==cancel_at)*allocation_cancel=1;}
static void *allocate(uint64_t bytes,int reserve){
    unsigned i;void*p;if(fault())return 0;CHECK(bytes && bytes<=50331648);
#ifdef _WIN32
    p=VirtualAlloc(0,(SIZE_T)bytes,reserve?MEM_RESERVE:MEM_RESERVE|MEM_COMMIT,reserve?PAGE_NOACCESS:PAGE_READWRITE);
#else
    p=mmap(0,bytes,reserve?PROT_NONE:PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);if(p==MAP_FAILED)p=0;
#endif
    CHECK(p);for(i=0;i<8 && allocations[i].live;++i){}CHECK(i<8);allocations[i]=(Allocation){p,bytes,1};++live;cancelled();return p;
}
void *ABI mem_reserve(uint64_t bytes){return allocate(bytes,1);}
void *ABI mem_alloc(uint64_t bytes){return allocate(bytes,0);}
void *ABI mem_commit(void *address,uint64_t bytes){
    unsigned i;void*result=0;for(i=0;i<8;++i)if(allocations[i].live && (uintptr_t)address>=(uintptr_t)allocations[i].base && (uintptr_t)address-(uintptr_t)allocations[i].base<=allocations[i].bytes && bytes<=allocations[i].bytes-((uintptr_t)address-(uintptr_t)allocations[i].base))break;
    CHECK(i<8 && bytes && !((uintptr_t)address&4095) && !(bytes&4095));if(fault())return 0;
#ifdef _WIN32
    result=VirtualAlloc(address,bytes,MEM_COMMIT,PAGE_READWRITE);
#else
    if(!mprotect(address,bytes,PROT_READ|PROT_WRITE))result=address;
#endif
    CHECK(result==address);cancelled();return result;
}
void ABI mem_free(void *p){unsigned i;if(!p)return;for(i=0;i<8;++i)if(allocations[i].live && allocations[i].base==p)break;CHECK(i<8);
#ifdef _WIN32
    CHECK(VirtualFree(p,0,MEM_RELEASE));
#else
    CHECK(!munmap(p,allocations[i].bytes));
#endif
    allocations[i].live=0;CHECK(live);--live;
}
static void allocation_tests(const unsigned char*data,size_t bytes){
    Context c;volatile uint32_t cancel=0;Options options={0,0,&cancel,1};unsigned total,i;
    CHECK(!live);operations=fail_at=cancel_at=0;allocation_cancel=&cancel;fresh(&c);CHECK(video_mp4_open(c.ctx,data,bytes,&options));total=operations;closed(&c);CHECK(!live && total);
    for(i=1;i<=total;++i){fresh(&c);cancel=0;operations=0;fail_at=i;CHECK(!video_mp4_open(c.ctx,data,bytes,&options) && u32(c.ctx+28)==12);CHECK(!u32(c.ctx+24));closed(&c);CHECK(!live);}
    fail_at=0;
    for(i=1;i<=total;++i){fresh(&c);cancel=0;operations=0;cancel_at=i;CHECK(!video_mp4_open(c.ctx,data,bytes,&options) && u32(c.ctx+28)==61);CHECK(!u32(c.ctx+24));closed(&c);CHECK(!live);}
    cancel_at=0;printf("{\"result\":\"passed\",\"allocation_failures\":%u,\"allocation_cancellations\":%u,\"checks\":%llu}\n",total,total,(unsigned long long)checks);
}
#endif

static void api_tests(const unsigned char*data,size_t bytes){
    Context a,b;Options options;volatile uint32_t ca=0,cb=0;unsigned char snapshot[8192];Packet pa,pb,previous;unsigned count=0;int ra,rb;
    fresh(&a);memset(&pa,0xa7,80);previous=pa;CHECK(video_mp4_next(a.ctx,&pa)==-1 && u32(a.ctx+28)==1 && !memcmp(&pa,&previous,80));CHECK(!video_mp4_rewind(a.ctx,2));closed(&a);
    fresh(&a);options=(Options){0,1,&ca,1};CHECK(!video_mp4_open(a.ctx,data,bytes,&options) && u32(a.ctx+28)==1);closed(&a);
    fresh(&a);options=(Options){0,0,&ca,0};CHECK(!video_mp4_open(a.ctx,data,bytes,&options) && u32(a.ctx+28)==1);closed(&a);
    fresh(&a);CHECK(!video_mp4_open(a.ctx,0,bytes,0) && u32(a.ctx+28)==1);closed(&a);
    fresh(&a);CHECK(!video_mp4_open(a.ctx,data,7,0) && u32(a.ctx+28)==1);closed(&a);
    fresh(&a);ca=1;options=(Options){0,0,&ca,1};CHECK(!video_mp4_open(a.ctx,data,bytes,&options) && u32(a.ctx+28)==61);closed(&a);ca=0;
    fresh(&a);CHECK(video_mp4_open(a.ctx,data,bytes,0) && u64(a.ctx+32)==1);closed(&a);
    fresh(&a);fresh(&b);options=(Options){0,0,&ca,1};CHECK(video_mp4_open(a.ctx,data,bytes,&options));options=(Options){0,0,&cb,UINT64_MAX};CHECK(video_mp4_open(b.ctx,data,bytes,&options));
    memcpy(snapshot,a.ctx,8192);CHECK(!video_mp4_open(a.ctx,0,0,0) && !memcmp(snapshot,a.ctx,8192));CHECK(!video_mp4_rewind(a.ctx,0) && !video_mp4_rewind(a.ctx,1) && !memcmp(snapshot,a.ctx,8192));
    do{ra=video_mp4_next(a.ctx,&pa);rb=video_mp4_next(b.ctx,&pb);CHECK(ra==rb);if(ra==1){CHECK(pa.epoch==1 && pb.epoch==UINT64_MAX);pb.epoch=1;CHECK(!memcmp(&pa,&pb,80));++count;}guards(&a);guards(&b);}while(ra==1);
    CHECK(ra==0 && count==u32(a.ctx+56));ca=1;previous=pa;CHECK(video_mp4_next(a.ctx,&pa)==-1 && !memcmp(&pa,&previous,80));ca=0;CHECK(video_mp4_next(a.ctx,&pa)==-1 && !video_mp4_rewind(a.ctx,2));closed(&a);
    memcpy(snapshot,b.ctx,8192);CHECK(!video_mp4_rewind(b.ctx,UINT64_MAX) && !video_mp4_rewind(b.ctx,1) && !memcmp(snapshot,b.ctx,8192));
    CHECK(video_mp4_next(b.ctx,&pb)==0);closed(&b);
#ifdef LAMP_MEMORY_ORACLE
    CHECK(!live);
#endif
    printf("{\"result\":\"passed\",\"checks\":%llu,\"independent_packets\":%u}\n",(unsigned long long)checks,count);
}

static void scan(const unsigned char*data,size_t bytes){
    Context c;Packet p,previous;volatile uint32_t cancel=0;Options options={0,0,&cancel,1};int r;unsigned n=0;fresh(&c);++guard_opens;r=video_mp4_open(c.ctx,data,bytes,&options);CHECK(r==0 || r==1);
    guard_fingerprint=hash(guard_fingerprint,(const unsigned char*)&r,4);guard_fingerprint=hash(guard_fingerprint,c.ctx+28,4);
    if(r){memset(&p,0xa7,80);while((r=video_mp4_next(c.ctx,&p))==1){int64_t raw_end;uint64_t offset;CHECK(n<u32(c.ctx+56) && p.index==n && p.epoch==1);CHECK(p.data>=data && p.size<=bytes && p.data<=data+bytes-p.size);CHECK(p.duration && p.duration<=INT64_MAX);CHECK(p.pts<=INT64_MAX-(int64_t)p.duration);
        CHECK(p.display_duration<=INT64_MAX && p.pts<=INT64_MAX-(int64_t)p.display_duration);raw_end=p.pts+(int64_t)p.display_duration;
        if(n)CHECK(p.dts>=previous.dts);previous=p;
        CHECK(!!(p.flags&8)==(p.size==0));CHECK(!!(p.flags&2)==(p.show_duration==0));
        if(p.show_duration){CHECK(p.show_pts>=0 && p.show_pts>=p.pts && p.show_duration<=INT64_MAX && p.show_pts<=INT64_MAX-(int64_t)p.show_duration);CHECK(p.show_pts+(int64_t)p.show_duration<=raw_end);}
        offset=(uint64_t)(p.data-data);guard_fingerprint=hash(guard_fingerprint,(const unsigned char*)&offset,8);guard_fingerprint=hash(guard_fingerprint,(const unsigned char*)&p.size,8);
        guard_fingerprint=hash(guard_fingerprint,(const unsigned char*)&p.dts,64);++n;++guard_packets;guards(&c);
    }CHECK(r==0 && n==u32(c.ctx+56));previous=p;CHECK(video_mp4_next(c.ctx,&p)==0 && !memcmp(&p,&previous,80));}
    else CHECK(u32(c.ctx+28));closed(&c);
#ifdef LAMP_MEMORY_ORACLE
    CHECK(!live);
#endif
}
static uint32_t random_state=0x4c414d50;
static uint32_t rnd(void){random_state^=random_state<<13;random_state^=random_state>>17;random_state^=random_state<<5;return random_state;}
static void guarded(const unsigned char*data,size_t bytes){
    size_t page,total;unsigned char*area,*end;unsigned i;
#ifdef _WIN32
    SYSTEM_INFO info;DWORD old;GetSystemInfo(&info);page=info.dwPageSize;total=((bytes+page-1)/page+2)*page;area=VirtualAlloc(0,total,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);CHECK(area);CHECK(VirtualProtect(area,page,PAGE_NOACCESS,&old) && VirtualProtect(area+total-page,page,PAGE_NOACCESS,&old));
#else
    page=sysconf(_SC_PAGESIZE);total=((bytes+page-1)/page+2)*page;area=mmap(0,total,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);CHECK(area!=MAP_FAILED);CHECK(!mprotect(area,page,PROT_NONE) && !mprotect(area+total-page,page,PROT_NONE));
#endif
    end=area+total-page;
    for(i=0;i<=1024;++i){size_t n=bytes*i/1024;memcpy(end-n,data,n);guard_fingerprint=hash(guard_fingerprint,end-n,n);scan(end-n,n);}
    for(i=0;i<2048;++i){size_t n,base=0,span;unsigned j;
        n=i%3==2?rnd()%(bytes+1):bytes;span=n;
        if(i%3!=2 && span>4096)span=4096;if(i%3==1)base=n-span;
        memcpy(end-n,data,n);for(j=0;j<4 && span;++j){size_t index=base+rnd()%span;unsigned char mask=(unsigned char)(1+rnd()%255);end[-(ptrdiff_t)n+(ptrdiff_t)index]^=mask;}
        guard_fingerprint=hash(guard_fingerprint,end-n,n);scan(end-n,n);
    }
    scan(data,bytes);
#ifdef _WIN32
    CHECK(VirtualFree(area,0,MEM_RELEASE));
#else
    CHECK(!munmap(area,total));
#endif
    printf("{\"result\":\"passed\",\"checks\":%llu,\"opens\":%llu,\"packets\":%llu,\"mutation_fingerprint\":\"%016llx\"}\n",(unsigned long long)checks,(unsigned long long)guard_opens,(unsigned long long)guard_packets,(unsigned long long)guard_fingerprint);
}
int main(int argc,char**argv){
    FILE*f,*out;long length;unsigned char*data;Context c;Options options;volatile uint32_t cancel=0;unsigned count,config_size,i,n=0;Packet packet,previous;uint32_t*ranks;int result;uint64_t first=1469598103934665603ULL,second=first;
    CHECK(argc==3 || argc==4);CHECK(sizeof(Packet)==80 && sizeof(Options)==24);
    f=fopen(argv[1],"rb");CHECK(f);CHECK(!fseek(f,0,SEEK_END));length=ftell(f);CHECK(length>=0 && length<=536870912);CHECK(!fseek(f,0,SEEK_SET));
    data=malloc((size_t)length+1);CHECK(data);CHECK(fread(data,1,length,f)==(size_t)length);fclose(f);
    if(!strcmp(argv[2],"--scan")){scan(data,length);printf("{\"result\":\"passed\",\"checks\":%llu,\"opens\":%llu,\"packets\":%llu,\"fingerprint\":\"%016llx\"}\n",(unsigned long long)checks,(unsigned long long)guard_opens,(unsigned long long)guard_packets,(unsigned long long)guard_fingerprint);free(data);return 0;}
    if(!strcmp(argv[2],"--api")){api_tests(data,length);free(data);return 0;}
    if(!strcmp(argv[2],"--guard")){guarded(data,length);free(data);return 0;}
#ifdef LAMP_MEMORY_ORACLE
    if(!strcmp(argv[2],"--alloc")){allocation_tests(data,length);free(data);return 0;}
#endif
    memset(&c,0xa5,sizeof(c));memset(c.ctx,0,sizeof(c.ctx));options=(Options){argc==4?(uint32_t)strtoul(argv[3],0,10):0,0,&cancel,1};
    if(!video_mp4_open(c.ctx,data,length,&options)){
        printf("{\"result\":\"rejected\",\"error\":%u}\n",u32(c.ctx+28));guards(&c);video_mp4_close(c.ctx);video_mp4_close(c.ctx);guards(&c);for(i=0;i<8192;++i)CHECK(!c.ctx[i]);free(data);return 1;
    }
    CHECK(!video_mp4_open(c.ctx,data,length,&options));guards(&c);
    count=u32(c.ctx+56);config_size=u32(c.ctx+96);CHECK(count<=1048576 && config_size>=7 && config_size<=8207);
    CHECK(u64(c.ctx+88)>=(uintptr_t)data && u64(c.ctx+88)+config_size<=(uintptr_t)data+length);
    ranks=malloc(((size_t)count+1)*4);CHECK(ranks);
    for(i=0;i<count;++i)ranks[i]=UINT32_MAX;
    for(i=0;i<count;++i){unsigned index=u32((const unsigned char*)(uintptr_t)u64(c.ctx+184)+i*4);CHECK(index<count && ranks[index]==UINT32_MAX);ranks[index]=i;}
    printf("{\"result\":\"opened\",\"count\":%u,\"track_id\":%u,\"video_tracks\":%u,\"media_scale\":%u,\"movie_scale\":%u,\"gap_ns\":%llu,\"edit_end_ns\":%llu,\"config\":\"",count,u32(c.ctx+112),u32(c.ctx+116),u32(c.ctx+104),u32(c.ctx+108),(unsigned long long)u64(c.ctx+160),(unsigned long long)u64(c.ctx+176));
    for(i=0;i<config_size;++i)printf("%02x",((const unsigned char*)(uintptr_t)u64(c.ctx+88))[i]);puts("\"}");
    out=fopen(argv[2],"wb");CHECK(out);{uint32_t header[]={0x31415048,config_size,count,0};CHECK(fwrite(header,16,1,out)==1 && fwrite((const void*)(uintptr_t)u64(c.ctx+88),config_size,1,out)==1);}
    memset(&packet,0xa7,sizeof(packet));
    while((result=video_mp4_next(c.ctx,&packet))==1){
        uint32_t size=(uint32_t)packet.size;CHECK(n<count && packet.index==n && packet.epoch==1);CHECK(packet.data>=data && packet.size<=(uint64_t)length && packet.data<=data+length-packet.size);CHECK(packet.duration && packet.duration<=INT64_MAX);
        if(n)CHECK(packet.dts>=previous.dts);previous=packet;
        first=hash(first,(const unsigned char*)&packet,80);guards(&c);
        printf("{\"index\":%u,\"offset\":%llu,\"size\":%llu,\"dts_ns\":%lld,\"pts_ns\":%lld,\"decode_duration_ns\":%llu,\"flags\":%u,\"show_pts_ns\":%lld,\"show_duration_ns\":%llu,\"display_duration_ns\":%llu}\n",n,(unsigned long long)(packet.data-data),(unsigned long long)packet.size,(long long)packet.dts,(long long)packet.pts,(unsigned long long)packet.duration,packet.flags,(long long)packet.show_pts,(unsigned long long)packet.show_duration,(unsigned long long)packet.display_duration);
        CHECK(fwrite(&size,4,1,out)==1 && fwrite(ranks+n,4,1,out)==1 && fwrite(&packet.dts,32,1,out)==1);
        CHECK(!packet.size || fwrite(packet.data,packet.size,1,out)==1);++n;
    }
    CHECK(result==0 && n==count);previous=packet;CHECK(video_mp4_next(c.ctx,&packet)==0 && !memcmp(&packet,&previous,80));fclose(out);
    CHECK(!video_mp4_rewind(c.ctx,0) && !video_mp4_rewind(c.ctx,1));CHECK(video_mp4_rewind(c.ctx,2));n=0;
    while((result=video_mp4_next(c.ctx,&packet))==1){CHECK(packet.epoch==2 && packet.index==n++);packet.epoch=1;second=hash(second,(const unsigned char*)&packet,80);}
    CHECK(result==0 && n==count && first==second);cancel=1;previous=packet;CHECK(video_mp4_next(c.ctx,&packet)==-1 && u32(c.ctx+28)==61 && !memcmp(&packet,&previous,80));cancel=0;CHECK(video_mp4_next(c.ctx,&packet)==-1);
    guards(&c);video_mp4_close(c.ctx);video_mp4_close(c.ctx);guards(&c);for(i=0;i<8192;++i)CHECK(!c.ctx[i]);free(ranks);free(data);
    printf("{\"result\":\"passed\",\"checks\":%llu,\"packets\":%u}\n",(unsigned long long)checks,count);return 0;
}
