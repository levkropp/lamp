/* Test-only ASF parser reads ending immediately at PAGE_NOACCESS. */
#include "lamp-test.h"
LAMP_ABI int asf_open(const void *,const void *);
LAMP_ABI void track_close(void);
LAMP_ABI void mts_close(void);
LAMP_ABI int decoder_open(const lamp_char *);
LAMP_ABI unsigned decoder_read(float *,unsigned);
LAMP_ABI void decoder_close(void);
extern uint64_t output_frames;
extern unsigned decode_error,track_choice,audio_tracks_count,audio_track_selected;
extern unsigned *ogg_cancel_ptr;

static unsigned char *guarded(unsigned bytes,void **allocation) {
    SYSTEM_INFO info;GetSystemInfo(&info);
    unsigned usable=(bytes+info.dwPageSize-1)/info.dwPageSize*info.dwPageSize;
    unsigned char *p=VirtualAlloc(NULL,usable+info.dwPageSize,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    DWORD old;if(!p||!VirtualProtect(p+usable,info.dwPageSize,PAGE_NOACCESS,&old))return NULL;
    *allocation=p;return p+usable-bytes;
}
static uint64_t le64(const unsigned char *p) {
    uint64_t value=0;for(unsigned i=0;i<8;i++)value|=(uint64_t)p[i]<<(8*i);return value;
}
static void put64(unsigned char *p,uint64_t value) {
    for(unsigned i=0;i<8;i++)p[i]=(unsigned char)(value>>(i*8));
}
static int large_file(unsigned char *data,unsigned bytes,const lamp_char *path,const lamp_char *reference) {
    uint64_t object=0x100000018ULL,logical=object+bytes,allocated=0;
    uint64_t header=le64(data+16);unsigned count=(unsigned)le64(data+24);
    put64(data+16,header+object);
    for(unsigned i=0;i<4;i++)data[24+i]=(unsigned char)((count+1)>>(i*8));
    /* File Properties is the first child in this independent fixture. */
    put64(data+70,logical);
    unsigned char unknown[24]={0};put64(unknown+16,object);
    lamp_file file;if(!lamp_sparse_create(path,logical,&file)||
       !lamp_sparse_put(file,0,data,30)||!lamp_sparse_put(file,30,unknown,24)||
       !lamp_sparse_put(file,30+object,data+30,bytes-30)||!lamp_sparse_close(file,path,&allocated))return 0;
    uint64_t reported=allocated;
#ifdef _WIN32
    /* Wine 8's GetCompressedFileSizeW reports the logical size for this
       sparse file. FILE_STANDARD_INFO supplies the actual allocation there;
       native filesystems can instead report it through the compressed size. */
    HANDLE h=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,0,NULL);
    FILE_STANDARD_INFO info;
    if(h==INVALID_HANDLE_VALUE)return 0;
    BOOL ok=GetFileInformationByHandleEx(h,FileStandardInfo,&info,sizeof(info));CloseHandle(h);
    if(ok&&(uint64_t)info.AllocationSize.QuadPart<allocated)allocated=info.AllocationSize.QuadPart;
#endif
    if(allocated>1024*1024)return 0;
    FILE *f=lamp_fopen(reference,LT("rb"));if(!f||!decoder_open(path)||!output_frames||decode_error)return 0;
    struct { uint64_t before;float values[2048];uint64_t after; } pcm;
    float expected[2048];uint64_t frames=0;unsigned n;
    for(;;){
        pcm.before=0x13579bdf2468ace0ULL;pcm.after=0x2468ace013579bdfULL;
        n=decoder_read(pcm.values,1024);if(!n)break;
        if(decode_error||pcm.before!=0x13579bdf2468ace0ULL||pcm.after!=0x2468ace013579bdfULL||
           fread(expected,8,n,f)!=n||memcmp(pcm.values,expected,n*8))return 0;
        frames+=n;
    }
    if(decode_error||frames!=output_frames||fgetc(f)!=EOF)return 0;
    fclose(f);decoder_close();
    printf("{\"result\":\"passed\",\"logical_bytes\":%llu,\"allocated_bytes\":%llu,\"initial_allocation_report\":%llu,\"frames\":%llu}\n",
           (unsigned long long)logical,(unsigned long long)allocated,(unsigned long long)reported,(unsigned long long)frames);return 1;
}
static int check(const unsigned char *data,unsigned bytes,int complete,int cancel) {
    void *allocation=NULL;unsigned char *p=guarded(bytes,&allocation);
    if(!p)return 0;if(bytes)memcpy(p,data,bytes);
    decode_error=track_choice=audio_tracks_count=audio_track_selected=0;
    unsigned cancelled=1;ogg_cancel_ptr=cancel?&cancelled:NULL;
    int opened=asf_open(p,p+bytes);ogg_cancel_ptr=NULL;
    if((complete&&!cancel)?!opened:(opened||!decode_error)) {
        fprintf(stderr,"Unexpected guarded open result: bytes=%u opened=%d error=%u\n",bytes,opened,decode_error);
        return 0;
    }
    track_close();mts_close();VirtualFree(allocation,0,MEM_RELEASE);return 1;
}
int lamp_main(int argc,lamp_char **argv) {
    if(argc!=2&&argc!=4)return 2;
    FILE *f=lamp_fopen(argv[1],LT("rb"));if(!f)return 2;
    fseek(f,0,SEEK_END);long length=ftell(f);rewind(f);
    if(length<80||length>4*1024*1024)return 2;
    unsigned char *data=malloc(length);if(!data||fread(data,1,length,f)!=(size_t)length)return 2;fclose(f);
    if(argc==4){int ok=large_file(data,length,argv[2],argv[3]);free(data);return ok?0:1;}
    unsigned checks=0;
    for(unsigned n=0;n<80;n++){if(!check(data,n,0,0))return 1;checks++;}
    unsigned header=(unsigned)le64(data+16);
    if(header>=(unsigned)length-50)return 2;
    /* All cuts within the Data Object header and the first packet, as well
       as object-header fields throughout the Header Object. */
    for(unsigned n=header;n<header+562&&n<(unsigned)length;n++){
        if(!check(data,n,0,0))return 1;checks++;
    }
    for(unsigned pos=30;pos<header;){
        if(pos+24>header)return 2;
        uint64_t size=le64(data+pos+16);if(size<24||size>header-pos)return 2;
        for(unsigned n=pos;n<pos+24;n++){if(!check(data,n,0,0))return 1;checks++;}
        pos+=(unsigned)size;
    }
    if(!check(data,length,1,0)||!check(data,length,1,1)||!check(data,length-1,0,0))return 1;
    checks+=3;free(data);
    printf("{\"result\":\"passed\",\"guard_checks\":%u,\"no_input_padding\":true}\n",checks);return 0;
}
