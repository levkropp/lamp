/* Original protected-input checks for the LATM PCE scanner. MIT. */
#include "lamp-test.h"
LAMP_ABI int loas_open(const void *,const void *);
LAMP_ABI unsigned track_read(float *,unsigned);
LAMP_ABI void track_close(void),loas_close(void);
extern unsigned decode_error;
extern uint64_t total_frames;
static unsigned page;
#define CHECK(x) do {if(!(x)){fprintf(stderr,"line %d: %s, error %u\n",__LINE__,#x,decode_error);return 0;}}while(0)
static int check(const unsigned char *data,unsigned bytes,int expected,int lifetime) {
    unsigned usable=((bytes?bytes:1)+page-1)/page*page;
    unsigned char *base=VirtualAlloc(NULL,usable+page,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    CHECK(base!=NULL);
    unsigned char *input=base+usable-bytes;DWORD old;
    if(bytes)memcpy(input,data,bytes);
    CHECK(VirtualProtect(base+usable,page,PAGE_NOACCESS,&old));
    CHECK(VirtualProtect(base,usable,PAGE_READONLY,&old));
    decode_error=0;int opened=loas_open(input,input+bytes);
    CHECK(expected<0 || opened==expected);
    CHECK(opened || decode_error);
    if(opened && lifetime) {
        CHECK(VirtualProtect(base,usable,PAGE_NOACCESS,&old));
        float pcm[2048*2];uint64_t total=0,frames=total_frames;unsigned n;
        while((n=track_read(pcm,2048))!=0){CHECK(n<=2048);total+=n;CHECK(total<=frames);}
        CHECK(!decode_error && total==frames && frames);
    }
    track_close();loas_close();VirtualFree(base,0,MEM_RELEASE);return 1;
}
int lamp_main(int argc,lamp_char **argv) {
    if(argc!=2)return 2;
    FILE *f=lamp_fopen(argv[1],LT("rb"));if(!f)return 2;
    fseek(f,0,SEEK_END);long size=ftell(f);rewind(f);
    if(size<3 || size>1024*1024)return 2;
    unsigned char *data=malloc(size),*changed=malloc(size);
    if(!data || !changed || fread(data,1,size,f)!=(size_t)size)return 2;fclose(f);
    SYSTEM_INFO info;GetSystemInfo(&info);page=info.dwPageSize;
    unsigned first=3+((data[1]&31)<<8)+data[2],prefixes=0;
    if(first>(unsigned)size)return 2;
    for(unsigned n=0;n<first;n++){if(!check(data,n,0,0))return 1;prefixes++;}
    if(!check(data,size,1,1))return 1;
    /* Full-width list counts and lengths, plus single-bit changes through
       the first mux/PCE header. Every input ends at an inaccessible page. */
    unsigned state=314159;
    for(unsigned i=0;i<600;i++) {
        memcpy(changed,data,size);state=state*1664525u+1013904223u;
        unsigned at=3+state%((unsigned)size-3<96?(unsigned)size-3:96);
        state=state*1664525u+1013904223u;
        if(i%3)changed[at]^=1u<<(state>>29);else changed[at]=(i%2)?255:0;
        if(!check(changed,size,-1,0))return 1;
    }
    free(data);free(changed);
    printf("{\"result\":\"passed\",\"guarded_prefixes\":%u,\"guarded_mutations\":600,\"input_lifetime\":\"released before reading PCM\"}\n",prefixes);
    return 0;
}
