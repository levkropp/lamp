/* Same encoded frames in one packet and guarded, separate borrowed packets. */
#include "lamp-test.h"
LAMP_ABI int ac3_track_open(const void *, unsigned, const void *, unsigned);
LAMP_ABI unsigned ac3_track_decode(const void *, unsigned, float *, unsigned);
LAMP_ABI void ac3_track_lookahead(const void *, unsigned);
LAMP_ABI void ac3_track_reset(void);
LAMP_ABI void ac3_track_close(void);
extern unsigned decode_error;

typedef struct { unsigned char *base, *data; unsigned bytes, samples, allocation; } Packet;

int lamp_main(int argc, lamp_char **argv) {
    if (argc!=2) return 2;
    FILE *file=lamp_fopen(argv[1],LT("rb"));
    if (!file) return 2;
    fseek(file,0,SEEK_END); long bytes=ftell(file); rewind(file);
    if (bytes<8 || bytes>1048576) return 2;
    unsigned char *data=malloc(bytes);
    if (!data || fread(data,1,bytes,file)!=(size_t)bytes) return 2;
    fclose(file);
    Packet packets[256]; unsigned count=0,total=0;
    SYSTEM_INFO info; GetSystemInfo(&info);
    for (unsigned at=0;at<(unsigned)bytes;) {
        if (count==256 || at+8>(unsigned)bytes) return 2;
        unsigned n=2*(((data[at+2]&7)<<8 | data[at+3])+1), blocks[]={1,2,3,6};
        if (n<8 || at+n>(unsigned)bytes) return 2;
        Packet *p=&packets[count++]; p->bytes=n; p->samples=256*blocks[(data[at+4]>>4)&3];
        unsigned usable=(n+info.dwPageSize-1)/info.dwPageSize*info.dwPageSize;
        p->allocation=usable+2*info.dwPageSize;
        p->base=VirtualAlloc(NULL,p->allocation,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
        if (!p->base) return 2;
        p->data=p->base+info.dwPageSize+usable-n;
        memcpy(p->data,data+at,n); DWORD old;
        if (!VirtualProtect(p->base,info.dwPageSize,PAGE_NOACCESS,&old) ||
            !VirtualProtect(p->base+info.dwPageSize,usable,PAGE_READONLY,&old) ||
            !VirtualProtect(p->base+info.dwPageSize+usable,info.dwPageSize,PAGE_NOACCESS,&old)) return 2;
        total+=p->samples; at+=n;
    }
    float *joined=malloc((total*2+4)*4), *split=malloc((total*2+4)*4);
    if (!joined || !split) return 2;
    for (unsigned i=0;i<total*2+4;i++) joined[i]=split[i]=12345;
    if (!ac3_track_open(NULL,0,data,bytes)) return 1;
    if (ac3_track_decode(data,bytes,joined+2,total)!=total || decode_error) return 1;
    ac3_track_close(); decode_error=0;
    if (!ac3_track_open(NULL,0,data,bytes)) return 1;
    unsigned offset=0;
    for (unsigned i=0;i<count;i++) {
        ac3_track_lookahead(i+1<count ? packets[i+1].data : NULL,i+1<count ? packets[i+1].bytes : 0);
        if (ac3_track_decode(packets[i].data,packets[i].bytes,split+2+offset*2,packets[i].samples)!=packets[i].samples || decode_error) return 1;
        offset+=packets[i].samples;
    }
    if (memcmp(joined,split,(total*2+4)*4)) { fprintf(stderr,"joined/split PCM mismatch\n"); return 1; }
    if (joined[0]!=12345 || joined[1]!=12345 || joined[total*2+2]!=12345 || joined[total*2+3]!=12345) return 1;
    /* Reset drops borrowed lookahead, even when the caller releases its packet.
       Reopen reseeds the shared LFG and reproduces the entire stream, including both random sources. */
    ac3_track_lookahead(packets[0].data,packets[0].bytes);
    ac3_track_close();
    if (!ac3_track_open(NULL,0,data,bytes)) return 1;
    memset(split+2,0,total*8);
    if (ac3_track_decode(data,bytes,split+2,total)!=total || decode_error || memcmp(joined,split,(total*2+4)*4)) return 1;
    ac3_track_reset(); decode_error=0;
    for (unsigned i=0;i<total*2+4;i++) split[i]=12345;
    if (ac3_track_decode(data,bytes,split+2,total-1) || decode_error!=100 ||
        split[0]!=12345 || split[1]!=12345 || split[total*2]!=12345 || split[total*2+1]!=12345 ||
        split[total*2+2]!=12345 || split[total*2+3]!=12345) return 1;
    /* A bad/missing next frame contributes zero, without changing the reader
       or random state used by the current frame. Inputs ending at guard
       pages already cover the full-size valid lookahead above. */
    ac3_track_close(); decode_error=0;
    if (!ac3_track_open(NULL,0,data,bytes)) return 1;
    if (ac3_track_decode(packets[0].data,packets[0].bytes,joined+2,packets[0].samples)!=packets[0].samples || decode_error) return 1;
    unsigned char *invalid=malloc(packets[0].bytes);
    if (!invalid) return 2;
    for (unsigned kind=0;kind<4;kind++) {
        memcpy(invalid,packets[0].data,packets[0].bytes);
        if (kind==0) invalid[packets[0].bytes-1]^=1; /* CRC */
        if (kind==1) invalid[0]=0; /* sync */
        if (kind==2) invalid[4]^=0x40; /* incompatible rate */
        ac3_track_close(); decode_error=0;
        if (!ac3_track_open(NULL,0,data,bytes)) return 1;
        ac3_track_lookahead(kind==3 ? packets[0].data+packets[0].bytes : invalid,
                           kind==3 ? 7 : packets[0].bytes);
        if (ac3_track_decode(packets[0].data,packets[0].bytes,split+2,packets[0].samples)!=packets[0].samples || decode_error ||
            memcmp(joined+2,split+2,packets[0].samples*8)) return 1;
    }
    free(invalid);
    /* Borrowed memory belongs to just one call. Compare explicit clearing
       with no setter on the next call after protecting the borrowed page. */
    ac3_track_close(); decode_error=0;
    if (!ac3_track_open(NULL,0,data,bytes)) return 1;
    ac3_track_lookahead(packets[0].data,packets[0].bytes);
    if (ac3_track_decode(packets[0].data,packets[0].bytes,split+2,packets[0].samples)!=packets[0].samples || decode_error) return 1;
    ac3_track_lookahead(NULL,0);
    if (ac3_track_decode(packets[0].data,packets[0].bytes,joined+2,packets[0].samples)!=packets[0].samples || decode_error) return 1;
    ac3_track_close(); decode_error=0;
    if (!ac3_track_open(NULL,0,data,bytes)) return 1;
    unsigned borrowed_bytes=(packets[0].bytes+info.dwPageSize-1)/info.dwPageSize*info.dwPageSize;
    unsigned char *borrowed=VirtualAlloc(NULL,borrowed_bytes,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    if (!borrowed) return 2;
    memcpy(borrowed,packets[0].data,packets[0].bytes);
    ac3_track_lookahead(borrowed,packets[0].bytes);
    if (ac3_track_decode(packets[0].data,packets[0].bytes,split+2,packets[0].samples)!=packets[0].samples || decode_error) return 1;
    DWORD old;
    if (!VirtualProtect(borrowed,borrowed_bytes,PAGE_NOACCESS,&old)) return 2;
    if (ac3_track_decode(packets[0].data,packets[0].bytes,split+2,packets[0].samples)!=packets[0].samples || decode_error ||
        memcmp(joined+2,split+2,packets[0].samples*8)) return 1;
    VirtualFree(borrowed,0,MEM_RELEASE);
    ac3_track_close();
    for (unsigned i=0;i<count;i++) VirtualFree(packets[i].base,0,MEM_RELEASE);
    free(data); free(joined); free(split);
    printf("{\"result\":\"exact guarded split/joined/reopen PCM and bounded capacity\",\"packets\":%u,\"frames\":%u,\"invalid_neighbor_cases\":4,\"borrowed_lifetime\":\"one decode call\"}\n",count,total);
    return 0;
}
