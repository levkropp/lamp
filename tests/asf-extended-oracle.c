/* Test-only protected Extended Stream Properties and work-budget oracle. */
#include "lamp-test.h"
LAMP_ABI int asf_open(const void *,const void *);
LAMP_ABI int asf_extended_stream_properties(const void *,const void *);
extern unsigned decode_error,track_choice,audio_tracks_count,audio_track_selected,asf_extended_budget;
extern void *asf_spread_scratch;
extern unsigned *ogg_cancel_ptr;
static unsigned checks,accepted,rejected;
static void put64(unsigned char *p,uint64_t value){for(unsigned i=0;i<8;i++)p[i]=(unsigned char)(value>>(i*8));}
static int check(unsigned char *data,unsigned bytes,int expected,int cancel,unsigned budget) {
    SYSTEM_INFO info;GetSystemInfo(&info);DWORD old;
    unsigned usable=(bytes+16+info.dwPageSize-1)/info.dwPageSize*info.dwPageSize;
    unsigned char *allocation=VirtualAlloc(NULL,usable+info.dwPageSize,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    if(!allocation||!VirtualProtect(allocation+usable,info.dwPageSize,PAGE_NOACCESS,&old))return 0;
    unsigned char *p=allocation+usable-bytes;memcpy(p,data,bytes);memset(p-16,0x35,16);
    /* A bounded prefix is itself an object. Preserve its original counts
       and lengths, changing only its envelope length for protected reads. */
    if(bytes>=24)put64(p+16,bytes);
    asf_open(NULL,NULL);decode_error=track_choice=audio_tracks_count=audio_track_selected=0;
    asf_extended_budget=budget;unsigned cancelled=1;ogg_cancel_ptr=cancel?&cancelled:NULL;
    int opened=asf_extended_stream_properties(p,p+bytes);ogg_cancel_ptr=NULL;
    if((expected>=0&&opened!=expected)||(opened?decode_error!=0:decode_error==0)||asf_spread_scratch||
       (!opened&&(audio_tracks_count||audio_track_selected))) {
        fprintf(stderr,"Protected extended result: bytes=%u opened=%d error=%u tracks=%u expected=%d\n",bytes,opened,decode_error,audio_tracks_count,expected);
        return 0;
    }
    for(unsigned i=0;i<16;i++)if(p[-16+(int)i]!=0x35)return 0;
    if(bytes>=24){if(memcmp(p,data,16)||memcmp(p+24,data+24,bytes-24))return 0;}
    else if(memcmp(p,data,bytes))return 0;
    if(opened)accepted++;else rejected++;checks++;VirtualFree(allocation,0,MEM_RELEASE);return 1;
}
int lamp_main(int argc,lamp_char **argv) {
    if(argc!=2&&argc!=3)return 2;
    FILE *f=lamp_fopen(argv[1],LT("rb"));if(!f)return 2;
    fseek(f,0,SEEK_END);long length=ftell(f);rewind(f);
    if(length<88||length>4*1024*1024)return 2;
    unsigned char *data=malloc(length);if(!data||fread(data,1,length,f)!=(size_t)length)return 2;fclose(f);
    if(!check(data,length,1,0,65536)||!check(data,length,0,1,65536))return 1;
    for(unsigned n=0;n<256&&n<(unsigned)length;n++)if(!check(data,n,-1,0,65536))return 1;
    for(unsigned n=length>64?length-64:0;n<(unsigned)length;n++)if(!check(data,n,-1,0,65536))return 1;
    unsigned count=data[84]|data[85]<<8;count+=data[86]|data[87]<<8;
    if(count&&!check(data,length,0,0,count-1))return 1;
    if(argc==3){
        unsigned iterations=lamp_atoi(argv[2]),state=9721;
        unsigned char *copy=malloc(length);if(!copy)return 2;
        for(unsigned i=0;i<iterations;i++){
            memcpy(copy,data,length);state=state*1664525u+1013904223u;unsigned pos=24+state%(length-24),n=length;
            if(i%4==0)n=pos;
            else if(i%4==1)copy[pos]^=1u<<(state>>29);
            else memset(copy+pos,i%4==2?0:0xff,length-pos<8?length-pos:8);
            if(!check(copy,n,-1,0,65536))return 1;
        }
        free(copy);
    }
    free(data);
    printf("{\"result\":\"passed\",\"protected_checks\":%u,\"accepted\":%u,\"rejected\":%u,\"seed\":9721,\"source_unchanged\":true,\"no_padding\":true,\"cancelled_publication\":false}\n",checks,accepted,rejected);return 0;
}
