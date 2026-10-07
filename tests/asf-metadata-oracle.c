/* Test-only metadata/cover reader at exact PAGE_NOACCESS boundaries. */
#include "lamp-test.h"
LAMP_ABI void tags_read(const void *, const void *);
LAMP_ABI void tags_clear(void);
LAMP_ABI void *tags_get(unsigned);
/* tags_get/cover_get return extra registers, captured by this tiny shim. */
extern unsigned asf_stream, decode_error, sample_rate;
extern unsigned *ogg_cancel_ptr;

struct tag_result { const unsigned char *data; uint64_t bytes; unsigned kind; };
static struct tag_result tag(unsigned key) {
    struct tag_result r;
    register unsigned argument __asm__("ecx")=key;
    __asm__ volatile("sub $40, %%rsp\n\tcall tags_get\n\tadd $40, %%rsp"
                     : "=a"(r.data), "=d"(r.bytes), "+c"(argument)
                     : : "r8","r9","r10","r11","xmm0","xmm1","xmm2","xmm3","xmm4","xmm5","memory","cc");
    r.kind=0;return r;
}
static struct tag_result cover(void) {
    struct tag_result r;
    register unsigned kind __asm__("r8");
    __asm__ volatile("sub $40, %%rsp\n\tcall cover_get\n\tadd $40, %%rsp"
                     : "=a"(r.data), "=d"(r.bytes), "=r"(kind)
                     : : "rcx","r9","r10","r11","xmm0","xmm1","xmm2","xmm3","xmm4","xmm5","memory","cc");
    r.kind=kind;return r;
}
static int check(const unsigned char *data,unsigned bytes,unsigned stream,int cancelled,int dump) {
    SYSTEM_INFO info;GetSystemInfo(&info);
    unsigned usable=(bytes+info.dwPageSize-1)/info.dwPageSize*info.dwPageSize;
    unsigned char *allocation=VirtualAlloc(NULL,usable+info.dwPageSize,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    DWORD old;if(!allocation||!VirtualProtect(allocation+usable,info.dwPageSize,PAGE_NOACCESS,&old))return 0;
    unsigned char *p=allocation+usable-bytes;if(bytes)memcpy(p,data,bytes);
    unsigned cancel=1;ogg_cancel_ptr=cancelled?&cancel:NULL;
    decode_error=0x13572468;sample_rate=0x24681357;asf_stream=stream;
    tags_read(p,p+bytes);ogg_cancel_ptr=NULL;
    if(decode_error!=0x13572468||sample_rate!=0x24681357)return 0;
    for(unsigned key=0;key<10;key++) {
        struct tag_result r=tag(key);
        if(r.bytes>4096||(!r.data&&r.bytes)||(cancelled&&r.bytes))return 0;
        if(dump&&r.data) {
            printf("tag %u ",key);for(unsigned i=0;i<r.bytes;i++)printf("%02x",r.data[i]);puts("");
        }
    }
    struct tag_result r=cover();
    if(r.data&&(r.data<p||r.data>p+bytes||r.bytes>(uint64_t)(p+bytes-r.data)||r.kind<1||r.kind>6))return 0;
    if(cancelled&&r.data)return 0;
    if(dump&&r.data) {
        printf("cover %u ",r.kind);for(uint64_t i=0;i<r.bytes;i++)printf("%02x",r.data[i]);puts("");
    }
    tags_clear();if(cover().data)return 0;
    for(unsigned key=0;key<10;key++)if(tag(key).data)return 0;
    VirtualFree(allocation,0,MEM_RELEASE);return 1;
}
int lamp_main(int argc,lamp_char **argv) {
    if(argc!=4)return 2;
    FILE *f=lamp_fopen(argv[2],LT("rb"));if(!f)return 2;
    fseek(f,0,SEEK_END);long size=ftell(f);rewind(f);
    if(size<0||size>2*1024*1024)return 2;
    unsigned char *data=malloc(size+1);if(!data||fread(data,1,size,f)!=(size_t)size)return 2;fclose(f);
    unsigned stream=lamp_atoi(argv[3]);int ok;
    if(!lamp_strcmp(argv[1],LT("dump")))ok=check(data,size,stream,0,1);
    else if(!lamp_strcmp(argv[1],LT("guard"))) {
        unsigned checks=0;
        if(size>8192)return 2;
        for(unsigned n=0;n<=(unsigned)size;n++) {
            if(!check(data,n,stream,0,0))return 1;checks++;
        }
        if(!check(data,size,stream,1,0))return 1;checks++;
        printf("{\"result\":\"passed\",\"guard_checks\":%u,\"unchanged_audio_state\":true,\"cancellation\":true,\"no_input_padding\":true}\n",checks);
        ok=1;
    } else return 2;
    free(data);return ok?0:1;
}
