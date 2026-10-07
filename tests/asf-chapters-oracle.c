/* Test-only chapter reader with no padding before a protected mapped end. */
#include "lamp-test.h"
LAMP_ABI void tags_read(const void *, const void *);
LAMP_ABI void tags_clear(void);
LAMP_ABI unsigned chapters_count(void);
LAMP_ABI void *tags_get(unsigned);
extern unsigned asf_stream, decode_error, sample_rate;
extern unsigned *ogg_cancel_ptr;

struct chapter {uint64_t ns; const unsigned char *text; unsigned bytes;};
static struct chapter get(unsigned index) {
    struct chapter c; register unsigned argument __asm__("ecx")=index;
    register unsigned length __asm__("r8");
    /* chapters_get is a leaf; capture its documented extra return registers. */
    __asm__ volatile("sub $40, %%rsp\n\tcall chapters_get\n\tadd $40, %%rsp"
        : "=a"(c.ns), "=d"(c.text), "=r"(length), "+c"(argument)
        : : "r9","r10","r11","memory","cc");
    c.bytes=length;return c;
}
static int check(const unsigned char *input,unsigned bytes,int cancelled,int dump) {
    SYSTEM_INFO info;GetSystemInfo(&info);
    unsigned usable=(bytes+info.dwPageSize-1)/info.dwPageSize*info.dwPageSize;
    unsigned char *allocation=VirtualAlloc(NULL,usable+info.dwPageSize,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    DWORD old;if(!allocation||!VirtualProtect(allocation+usable,info.dwPageSize,PAGE_NOACCESS,&old))return 0;
    unsigned char *p=allocation+usable-bytes;if(bytes)memcpy(p,input,bytes);
    unsigned cancel=1;ogg_cancel_ptr=cancelled?&cancel:NULL;
    decode_error=0x13572468;sample_rate=0x24681357;asf_stream=3;
    tags_read(p,p+bytes);ogg_cancel_ptr=NULL;
    unsigned count=chapters_count();
    if(decode_error!=0x13572468||sample_rate!=0x24681357||count>1024||(cancelled&&count))return 0;
    for(unsigned i=0;i<count;i++) {
        struct chapter c=get(i);
        if(c.bytes>1024||(!c.text&&c.bytes))return 0;
        if(dump) {
            printf("chapter %llu ",(unsigned long long)c.ns);
            for(unsigned j=0;j<c.bytes;j++)printf("%02x",c.text[j]);puts("");
        }
    }
    struct chapter none=get(count);if(none.ns||none.text||none.bytes)return 0;
    tags_clear();if(chapters_count())return 0;
    none=get(0);if(none.ns||none.text||none.bytes)return 0;
    VirtualFree(allocation,0,MEM_RELEASE);return 1;
}
int lamp_main(int argc,lamp_char **argv) {
    if(argc!=3)return 2;
    FILE *f=lamp_fopen(argv[2],LT("rb"));if(!f)return 2;
    fseek(f,0,SEEK_END);long bytes=ftell(f);rewind(f);
    if(bytes<0||bytes>4*1024*1024)return 2;
    unsigned char *data=malloc(bytes+1);if(!data||fread(data,1,bytes,f)!=(size_t)bytes)return 2;fclose(f);
    int ok;
    if(!lamp_strcmp(argv[1],LT("dump")))ok=check(data,bytes,0,1);
    else if(!lamp_strcmp(argv[1],LT("guard"))) {
        if(bytes>8192)return 2;unsigned checks=0;
        for(unsigned n=0;n<=(unsigned)bytes;n++){if(!check(data,n,0,0))return 1;checks++;}
        if(!check(data,bytes,1,0))return 1;checks++;
        printf("{\"result\":\"passed\",\"guard_checks\":%u,\"unchanged_audio_state\":true,\"clear\":true,\"cancellation\":true,\"no_input_padding\":true}\n",checks);ok=1;
    }else return 2;
    free(data);return ok?0:1;
}
