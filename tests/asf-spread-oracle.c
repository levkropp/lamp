/* Test-only spreading matrix, guarded buffers, cancellation and ownership. */
#include "lamp-test.h"
LAMP_ABI int asf_despread(const void *,void *,unsigned,unsigned,unsigned,unsigned);
LAMP_ABI int decoder_open(const lamp_char *);
LAMP_ABI void decoder_close(void);
LAMP_ABI int asf_open(const void *,const void *);
LAMP_ABI void track_close(void);
LAMP_ABI void mts_close(void);
extern unsigned *ogg_cancel_ptr;
extern unsigned decode_error;
extern void *asf_spread_scratch;
extern unsigned track_choice,audio_tracks_count,audio_track_selected;
static unsigned cases,largest;
static int matrix(unsigned span,unsigned rows,unsigned chunk) {
    unsigned packet=rows*chunk,n=span*packet;
    SYSTEM_INFO info;GetSystemInfo(&info);
    unsigned usable=(n+16+info.dwPageSize-1)/info.dwPageSize*info.dwPageSize;
    unsigned char *src=VirtualAlloc(NULL,usable+info.dwPageSize,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    unsigned char *dst=VirtualAlloc(NULL,usable+info.dwPageSize,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    unsigned char *ordered=malloc(n);DWORD old;
    if(!src||!dst||!ordered||!VirtualProtect(src+usable,info.dwPageSize,PAGE_NOACCESS,&old)||
       !VirtualProtect(dst+usable,info.dwPageSize,PAGE_NOACCESS,&old))return 0;
    unsigned char *a=src+usable-n,*b=dst+usable-n;
    memset(a-16,0x35,16);memset(b-16,0x46,16);
    for(unsigned i=0;i<n;i++)ordered[i]=(unsigned char)((i*1137u+(i>>7)*331u+59u)>>3);
    /* Serializer writes each matrix column from an independently numbered
       row-major byte stream. Decoder output must recover that byte stream. */
    for(unsigned col=0;col<span;col++)for(unsigned row=0;row<rows;row++)
        memcpy(a+(col*rows+row)*chunk,ordered+(row*span+col)*chunk,chunk);
    memset(b,0xa5,n);decode_error=0x13572468;
    if(!asf_despread(a,b,n,span,packet,chunk)||memcmp(b,ordered,n)||decode_error!=0x13572468)return 0;
    for(unsigned i=0;i<16;i++)if(a[-16+(int)i]!=0x35||b[-16+(int)i]!=0x46)return 0;
    /* Source remains unchanged; cancellation must precede the first write. */
    for(unsigned col=0;col<span;col++)for(unsigned row=0;row<rows;row++)
        if(memcmp(a+(col*rows+row)*chunk,ordered+(row*span+col)*chunk,chunk))return 0;
    unsigned cancel=1;ogg_cancel_ptr=&cancel;memset(b,0xa5,n);
    int result=asf_despread(a,b,n,span,packet,chunk);ogg_cancel_ptr=NULL;if(result)return 0;
    for(unsigned i=0;i<n;i++)if(b[i]!=0xa5)return 0;
    /* Invalid capacities and dimensions must reject even inaccessible input. */
    const void *guard=src+usable;
    const unsigned bad[][4]={{n-1,span,packet,chunk},{n+1,span,packet,chunk},{n,0,packet,chunk},
        {n,256,packet,chunk},{n,span,0,chunk},{n,span,65536,chunk},{n,span,packet,0},
        {n,span,packet,65536},{n,span,1,2}};
    for(unsigned i=0;i<sizeof(bad)/sizeof(*bad);i++)if(asf_despread(guard,b,bad[i][0],bad[i][1],bad[i][2],bad[i][3]))return 0;
    if(asf_despread(NULL,b,n,span,packet,chunk)||asf_despread(a,NULL,n,span,packet,chunk)||
       asf_despread(a,a,n,span,packet,chunk)||(n>1&&asf_despread(a,a+1,n,span,packet,chunk))||
       asf_despread(a,(void *)(UINTPTR_MAX-n+1),n,span,packet,chunk)||
       asf_despread((void *)(UINTPTR_MAX-n+1),b,n,span,packet,chunk))return 0;
    for(unsigned i=0;i<n;i++)if(b[i]!=0xa5)return 0;
    VirtualFree(src,0,MEM_RELEASE);VirtualFree(dst,0,MEM_RELEASE);free(ordered);
    cases++;if(n>largest)largest=n;return 1;
}
int lamp_main(int argc,lamp_char **argv) {
    if(argc==4&&!lamp_strcmp(argv[1],LT("mutate"))){
        FILE *f=lamp_fopen(argv[2],LT("rb"));if(!f)return 2;
        fseek(f,0,SEEK_END);long length=ftell(f);rewind(f);
        if(length<80||length>4*1024*1024)return 2;
        unsigned char *original=malloc(length);if(!original||fread(original,1,length,f)!=(size_t)length)return 2;fclose(f);
        SYSTEM_INFO info;GetSystemInfo(&info);unsigned usable=(length+16+info.dwPageSize-1)/info.dwPageSize*info.dwPageSize;
        unsigned char *allocation=VirtualAlloc(NULL,usable+info.dwPageSize,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);DWORD old;
        if(!allocation||!VirtualProtect(allocation+usable,info.dwPageSize,PAGE_NOACCESS,&old))return 2;
        unsigned count=lamp_atoi(argv[3]),state=9427,accepted=0,rejected=0;
        for(unsigned i=0;i<count;i++){
            state=state*1664525u+1013904223u;unsigned pos=30+state%(length-30),n=length;
            if(i%4==0)n=pos;
            unsigned char *p=allocation+usable-n;memset(p-16,0x35,16);memcpy(p,original,n);
            if(i%4==1)p[pos]^=1u<<(state>>29);
            if(i%4>=2)memset(p+pos,i%4==2?0xff:0,n-pos<8?n-pos:8);
            decode_error=track_choice=audio_tracks_count=audio_track_selected=0;
            int opened=asf_open(p,p+n);
            if(asf_spread_scratch||(opened?decode_error!=0:decode_error==0))return 1;
            if(opened)accepted++;else rejected++;
            track_close();mts_close();
            for(unsigned k=0;k<16;k++)if(p[-16+(int)k]!=0x35)return 1;
        }
        VirtualFree(allocation,0,MEM_RELEASE);free(original);
        printf("{\"result\":\"passed\",\"guarded_mutations\":%u,\"seed\":9427,\"accepted\":%u,\"rejected\":%u,\"scratch_released\":true}\n",count,accepted,rejected);return 0;
    }
    if(argc==3){
        for(unsigned i=0;i<40;i++){
            if(decoder_open(argv[2])||!decode_error||asf_spread_scratch)return 1;decoder_close();
            if(!decoder_open(argv[1])||decode_error||asf_spread_scratch)return 1;decoder_close();
        }
        puts("{\"result\":\"passed\",\"failed_opens_then_reopens\":40,\"scratch_released\":true}");return 0;
    }
    if(argc==2){
        /* Repeated successful opens free private transform scratch before
           returning; cancelled opens and reopen cannot retain its pointer. */
        for(unsigned i=0;i<40;i++) {
            if(!decoder_open(argv[1])||decode_error||asf_spread_scratch)return 1;decoder_close();
            unsigned cancel=1;ogg_cancel_ptr=&cancel;int result=decoder_open(argv[1]);ogg_cancel_ptr=NULL;
            if(result||!decode_error||asf_spread_scratch)return 1;decoder_close();
        }
        puts("{\"result\":\"passed\",\"opens\":40,\"cancelled_opens\":40,\"scratch_released\":true}");return 0;
    }
    if(argc!=1)return 2;
    unsigned char literal[12];
    if(!asf_despread("ACEBDF",literal,6,2,3,1)||memcmp(literal,"ABCDEF",6)||
       !asf_despread("ADBECF",literal,6,3,2,1)||memcmp(literal,"ABCDEF",6)||
       !asf_despread("abefijcdghkl",literal,12,2,6,2)||memcmp(literal,"abcdefghijkl",12))return 1;
    const unsigned spans[]={1,2,3,5,17,127,255},rows[]={1,2,3,7,63,255},chunks[]={1,2,3,4,7,16,31,256,1024,4096,32767,65535};
    for(unsigned s=0;s<sizeof(spans)/sizeof(*spans);s++)for(unsigned r=0;r<sizeof(rows)/sizeof(*rows);r++)
        for(unsigned c=0;c<sizeof(chunks)/sizeof(*chunks);c++)
            if(rows[r]*chunks[c]<=65535&&spans[s]*rows[r]*chunks[c]<=1<<20&&
               !matrix(spans[s],rows[r],chunks[c]))return 1;
    if(!matrix(255,2,32767)||!matrix(255,65535,1))return 1;
    printf("{\"result\":\"passed\",\"matrices\":%u,\"literal_vectors\":3,\"largest_bytes\":%u,\"source_and_destination_guards\":true,\"source_unchanged\":true,\"cancel_before_write\":true,\"invalid_inputs_inaccessible\":true}\n",cases,largest);return 0;
}
