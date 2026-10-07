/* Guarded AAC configuration/packet lifetimes and bounded decoding. MIT. */
#include "lamp-test.h"
LAMP_ABI int aac_track_open(const void *,unsigned,const void *,unsigned);
LAMP_ABI unsigned aac_track_samples(const void *,unsigned);
LAMP_ABI unsigned aac_track_decode(const void *,unsigned,float *,unsigned);
LAMP_ABI void aac_track_reset(void),aac_track_close(void);
extern unsigned decode_error,source_channels,sample_rate;
typedef struct { unsigned char *base,*data; size_t usable,allocation; unsigned bytes; } Guard;
static unsigned page;
static Guard guard(unsigned bytes,const void *input) {
    size_t usable=((bytes?bytes:1)+page-1)/page*page;
    Guard g={NULL,NULL,usable,usable+2*page,bytes};
    g.base=VirtualAlloc(NULL,g.allocation,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    if(!g.base)exit(2);
    g.data=g.base+page+usable-bytes;
    if(input && bytes)memcpy(g.data,input,bytes);
    DWORD old;
    if(!VirtualProtect(g.base,page,PAGE_NOACCESS,&old) ||
       !VirtualProtect(g.base+page+usable,page,PAGE_NOACCESS,&old) ||
       (input && !VirtualProtect(g.base+page,usable,PAGE_READONLY,&old)))exit(2);
    return g;
}
static void release(Guard *g) {VirtualFree(g->base,0,MEM_RELEASE);}
static unsigned word(const unsigned char *p) {unsigned n;memcpy(&n,p,4);return n;}
#define CHECK(x) do { if(!(x)) {fprintf(stderr,"line %d: %s; error %u\n",__LINE__,#x,decode_error);return 1;} }while(0)
int lamp_main(int argc,lamp_char **argv) {
    if(argc!=2)return 2;
    FILE *f=lamp_fopen(argv[1],LT("rb"));if(!f)return 2;
    fseek(f,0,SEEK_END);long size=ftell(f);rewind(f);
    if(size<8 || size>16*1024*1024)return 2;
    unsigned char *data=malloc(size);if(!data || fread(data,1,size,f)!=(size_t)size)return 2;fclose(f);
    unsigned config_bytes=word(data),count=word(data+4),at=8;
    if(!config_bytes || config_bytes>512 || !count || count>256 || config_bytes>(unsigned)size-at)return 2;
    SYSTEM_INFO info;GetSystemInfo(&info);page=info.dwPageSize;
    Guard config=guard(config_bytes,data+at),packets[256];at+=config_bytes;
    for(unsigned i=0;i<count;i++) {
        if(at+4>(unsigned)size)return 2;
        unsigned n=word(data+at);at+=4;
        if(!n || n>(unsigned)size-at)return 2;
        packets[i]=guard(n,data+at);at+=n;
    }
    if(at!=(unsigned)size)return 2;
    free(data);decode_error=0;
    CHECK(aac_track_open(config.data,config.bytes,packets[0].data,packets[0].bytes));
    CHECK(source_channels>=1 && source_channels<=8);
    unsigned frames=aac_track_samples(packets[0].data,packets[0].bytes);
    CHECK(frames==1024 || frames==2048);
    Guard output=guard(frames*8,NULL);
    float *baseline=malloc((size_t)count*2048*8);CHECK(baseline!=NULL);
    unsigned total=0;
    for(unsigned i=0;i<count;i++) {
        unsigned n=aac_track_decode(packets[i].data,packets[i].bytes,(float *)output.data,frames);
        CHECK(n && !decode_error);CHECK(n==frames);
        memcpy(baseline+total*2,output.data,n*8);total+=n;
    }
    aac_track_close();decode_error=0;
    CHECK(aac_track_open(config.data,config.bytes,packets[0].data,packets[0].bytes));
    /* Configuration bytes belong to the caller and can be released after open. */
    DWORD old;CHECK(VirtualProtect(config.base+page,config.usable,PAGE_NOACCESS,&old));
    for(unsigned i=0;i<count;i++) {
        unsigned n=aac_track_decode(packets[i].data,packets[i].bytes,(float *)output.data,frames);
        CHECK(n==frames && !decode_error && !memcmp(output.data,baseline+i*frames*2,n*8));
    }
    CHECK(VirtualProtect(config.base+page,config.usable,PAGE_READONLY,&old));
    aac_track_reset();decode_error=0;
    Guard short_output=guard((frames-1)*8,NULL);memset(short_output.data,0xa5,short_output.bytes);
    CHECK(!aac_track_decode(packets[0].data,packets[0].bytes,(float *)short_output.data,frames-1) && decode_error==100);
    for(unsigned i=0;i<short_output.bytes;i++)CHECK(short_output.data[i]==0xa5);
    release(&short_output);
    /* A rejected in-band replacement must not overwrite the active map.
       Every generated first packet begins with ID_PCE; change its program tag. */
    CHECK((packets[0].data[0]>>5)==5);
    unsigned char *replacement=malloc(packets[0].bytes);CHECK(replacement!=NULL);
    memcpy(replacement,packets[0].data,packets[0].bytes);replacement[0]^=2;
    Guard changed=guard(packets[0].bytes,replacement);free(replacement);
    aac_track_reset();decode_error=0;
    CHECK(!aac_track_decode(changed.data,changed.bytes,(float *)output.data,frames) && decode_error==101);
    release(&changed);aac_track_reset();decode_error=0;
    CHECK(aac_track_decode(packets[0].data,packets[0].bytes,(float *)output.data,frames)==frames && !decode_error);
    CHECK(!memcmp(output.data,baseline,frames*8));
    aac_track_close();
    unsigned prefixes=0;
    for(unsigned n=0;n<config.bytes;n++) {
        Guard input=guard(n,config.data);decode_error=0;
        CHECK(!aac_track_open(input.data,n,packets[0].data,packets[0].bytes) && decode_error);
        aac_track_close();release(&input);prefixes++;
    }
    decode_error=0;CHECK(aac_track_open(config.data,config.bytes,packets[0].data,packets[0].bytes));
    for(unsigned n=0;n<packets[0].bytes;n++) {
        Guard input=guard(n,packets[0].data);aac_track_reset();decode_error=0;
        CHECK(!aac_track_decode(input.data,n,(float *)output.data,frames) && decode_error);
        release(&input);prefixes++;
    }
    aac_track_close();
    /* Mutated ASC bytes touch the complete PCE, including counts and maximum
       comments. Accepted configurations must still stay inside all guards. */
    unsigned state=19790427,accepted=0;
    unsigned char altered[512];
    for(unsigned i=0;i<600;i++) {
        memcpy(altered,config.data,config.bytes);
        state=state*1664525u+1013904223u;unsigned width=(i%4 && config.bytes>32)?32:config.bytes;unsigned where=state%width;
        state=state*1664525u+1013904223u;altered[where]^=(unsigned char)(1u<<(state>>29));
        Guard input=guard(config.bytes,altered);decode_error=0;
        if(aac_track_open(input.data,input.bytes,packets[0].data,packets[0].bytes)) {
            CHECK(source_channels>=1 && source_channels<=8);
            unsigned n=aac_track_decode(packets[0].data,packets[0].bytes,(float *)output.data,frames);
            CHECK(n<=frames);accepted++;
        }
        aac_track_close();release(&input);
    }
    free(baseline);release(&output);release(&config);
    for(unsigned i=0;i<count;i++)release(&packets[i]);
    printf("{\"result\":\"passed\",\"packets\":%u,\"frames\":%u,\"guarded_prefixes\":%u,\"guarded_mutations\":600,\"accepted_mutations\":%u,\"config_lifetime\":\"released after open\",\"replacement\":\"rejected without changing active map\",\"capacity\":\"no writes below required frames\"}\n",count,total,prefixes,accepted);
    return 0;
}
