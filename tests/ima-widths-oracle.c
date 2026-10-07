/* Test-only protected packet/output boundaries for WAVE IMA code widths. */
#include "lamp-test.h"
LAMP_ABI int adpcm_track_open(const void *,unsigned,const void *,unsigned);
LAMP_ABI unsigned adpcm_track_samples(const void *,unsigned);
LAMP_ABI int adpcm_track_decode(const void *,unsigned,float *,unsigned);
LAMP_ABI void adpcm_track_reset(void);
LAMP_ABI void adpcm_track_close(void);
extern unsigned decode_error,source_bits,source_channels;

static unsigned char *read_file(const lamp_char *path,unsigned *bytes) {
    FILE *f=lamp_fopen(path,LT("rb"));if(!f)return NULL;
    fseek(f,0,SEEK_END);long n=ftell(f);rewind(f);
    if(n<=0||n>8*1024*1024){fclose(f);return NULL;}
    unsigned char *p=malloc(n);
    if(!p||fread(p,1,n,f)!=(size_t)n){free(p);fclose(f);return NULL;}
    fclose(f);*bytes=(unsigned)n;return p;
}
static unsigned char *guarded(unsigned bytes,void **allocation) {
    SYSTEM_INFO info;GetSystemInfo(&info);
    unsigned usable=(bytes+info.dwPageSize-1)/info.dwPageSize*info.dwPageSize;
    unsigned char *p=VirtualAlloc(NULL,usable+info.dwPageSize,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    DWORD old;if(!p||!VirtualProtect(p+usable,info.dwPageSize,PAGE_NOACCESS,&old))return NULL;
    *allocation=p;return p+usable-bytes;
}
int lamp_main(int argc,lamp_char **argv) {
    if(argc!=4)return 2;
    unsigned fs=0,ps=0,rs=0;
    unsigned char *fmt=read_file(argv[1],&fs),*packet=read_file(argv[2],&ps),*reference=read_file(argv[3],&rs);
    if(!fmt||!packet||!reference||fs<16||rs%8)return 2;
    unsigned channels=fmt[2]|fmt[3]<<8,bits=fmt[14]|fmt[15]<<8,align=fmt[12]|fmt[13]<<8,frames=rs/8;
    void *fa=NULL,*pa=NULL,*oa=NULL;
    unsigned char *f=guarded(fs,&fa),*p=guarded(ps,&pa),*o=guarded(rs+8,&oa);
    if(!f||!p||!o)return 2;
    memcpy(f,fmt,fs);memcpy(p,packet,ps);o+=8;
    if(!adpcm_track_open(f,fs,NULL,0)||source_bits!=bits||source_channels!=channels||
       adpcm_track_samples(p,ps)!=frames||decode_error)return 1;
    memset(o,0xa5,rs);*(uint64_t *)(o-8)=0x13579bdf2468ace0ULL;
    if(adpcm_track_decode(p,ps,(float *)o,frames)!=(int)frames||decode_error||memcmp(o,reference,rs)||
       *(uint64_t *)(o-8)!=0x13579bdf2468ace0ULL)return 1;
    /* Error paths must not touch the destination or read beyond the packet.
       The packet ends immediately before PAGE_NOACCESS; no padding exists. */
    const unsigned sizes[]={ps,align+1,channels*4-1};
    for(unsigned i=0;i<3;i++){
        adpcm_track_reset();decode_error=0;memset(o,0xa5,rs);
        unsigned capacity=i==0?frames-1:frames;
        if(adpcm_track_decode(p,sizes[i],(float *)o,capacity)!=-1||decode_error!=100)return 1;
        for(unsigned at=0;at<rs;at++)if(o[at]!=0xa5)return 1;
    }
    /* The reserved header byte is part of the signed 16-bit step index. */
    p[2]=0;p[3]=1;adpcm_track_reset();decode_error=0;memset(o,0xa5,rs);
    if(adpcm_track_decode(p,ps,(float *)o,frames)!=-1||decode_error!=100)return 1;
    for(unsigned at=0;at<rs;at++)if(o[at]!=0xa5)return 1;
    adpcm_track_close();VirtualFree(fa,0,MEM_RELEASE);VirtualFree(pa,0,MEM_RELEASE);VirtualFree(oa,0,MEM_RELEASE);
    free(fmt);free(packet);free(reference);
    printf("{\"result\":\"passed\",\"guard_checks\":5,\"frames\":%u,\"bits\":%u,\"channels\":%u}\n",frames,bits,channels);
    return 0;
}
