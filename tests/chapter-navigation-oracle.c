/* Test-only chapter boundaries and heard-file navigation with decode ahead. */
#include "lamp-test.h"
LAMP_ABI uint64_t chapter_target_from(unsigned, uint64_t, uint64_t, const uint64_t *, unsigned);
LAMP_ABI int queue_begin(const lamp_char **,unsigned);
LAMP_ABI unsigned queue_read(float *,unsigned);
LAMP_ABI void queue_start(uint64_t);
LAMP_ABI void decoder_close(void);
extern unsigned queue_index,queue_rate,queue_target,decode_error;

/* The separate test-only assembly thunk exposes the RDX time to C. */
LAMP_ABI uint64_t chapter_navigate_probe(unsigned,unsigned,uint64_t,int);

static unsigned boundaries(void) {
    const uint64_t ns[]={6500999999ULL,0,3250999999ULL,1250000499ULL,3250000000ULL,12000000000ULL,UINT64_MAX};
    const struct {unsigned command;uint64_t position,limit,want;} cases[]={
        {6,0,9000,1250},{6,1249,9000,1250},{6,1250,9000,3250},
        {6,3250,9000,6500},{6,6500,9000,6500},{6,9000,9000,9000},
        {7,1000,9000,0},{7,6500,9000,3250},{7,6501,9000,3250},
        {7,6250,9000,1250},{7,6251,9000,3250},{7,9500,9000,3250},
        {7,9501,9000,6500},{6,1250,3250,1250},{7,9000,3250,1250},
        {6,6500,0,12000},{7,UINT64_MAX,9000,6500},{99,500,9000,500}
    };
    for (unsigned i=0;i<sizeof(cases)/sizeof(*cases);i++) {
        uint64_t got=chapter_target_from(cases[i].command,cases[i].position,cases[i].limit,ns,7);
        if (got!=cases[i].want) {fprintf(stderr,"chapter boundary %u: %llu != %llu\n",i,(unsigned long long)got,(unsigned long long)cases[i].want);return 0;}
    }
    if (chapter_target_from(6,500,9000,NULL,0)!=500 ||
        chapter_target_from(7,500,9000,NULL,1)!=500 ||
        chapter_target_from(6,500,9000,ns,1025)!=500 ||
        chapter_target_from(7,500,1000,ns+5,2)!=500) return 0;
    /* Both scans may touch exactly 1024 starts, ending at a guard page. */
    SYSTEM_INFO info;GetSystemInfo(&info);unsigned usable=(8192+info.dwPageSize-1)/info.dwPageSize*info.dwPageSize;
    unsigned char *memory=VirtualAlloc(NULL,usable+info.dwPageSize,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    if (!memory) return 0;
    uint64_t *table=(uint64_t *)(memory+usable-8192);
    for (unsigned i=0;i<1024;i++) table[i]=(1023-i)*1000000ULL;
    DWORD old;if (!VirtualProtect(memory+usable,info.dwPageSize,PAGE_NOACCESS,&old)) return 0;
    if (chapter_target_from(6,1022,0,table,1024)!=1023 ||
        chapter_target_from(7,1023,0,table,1024)!=1022) return 0;
    VirtualFree(memory,0,MEM_RELEASE);
    return sizeof(cases)/sizeof(*cases)+6;
}

int lamp_main(int argc,lamp_char **argv) {
    unsigned n=boundaries();if (!n) return 1;
    if (argc==1) {printf("{\"boundaries\":%u,\"guarded_starts\":1024}\n",n);return 0;}
    if (argc!=6) return 2;
    const lamp_char *paths[]={argv[1],argv[2]};unsigned rate=lamp_atoi(argv[4]),has_chapters=lamp_atoi(argv[5]);
    FILE *file=lamp_fopen(argv[3],LT("rb"));if (!file) return 2;
    fseek(file,0,SEEK_END);long bytes=ftell(file);rewind(file);
    if (bytes<rate*8 || bytes%8) return 2;
    unsigned char *reference=malloc(bytes);if (!reference || fread(reference,1,bytes,file)!=(size_t)bytes) return 2;fclose(file);
    const struct {unsigned command;uint64_t position,want;} cases[]={
        {6,500,1250},{6,1250,3250},{6,3250,6500},{7,4400,1250},
        {7,6500,3250},{7,1000,0},{7,8800,3250},{6,7000,7000}
    };
    struct {uint64_t before;float pcm[8192];uint64_t after;} buffer;
    for (unsigned i=0;i<sizeof(cases)/sizeof(*cases);i++) {
        queue_target=rate;decode_error=0;
        if (!queue_begin(paths,2) || queue_rate!=rate) return 1;
        unsigned reads=0;
        while (queue_index==0 && reads++<10000) {if (!queue_read(buffer.pcm,4096) || decode_error) return 1;}
        if (queue_index!=1) return 1; /* global chapter data now belongs to the later file */
        uint64_t want=has_chapters?cases[i].want:cases[i].position;
        uint64_t got=chapter_navigate_probe(cases[i].command,0,cases[i].position,0);
        if (got!=want || queue_index!=0 || decode_error) {fprintf(stderr,"heard chapter %u: %llu != %llu\n",i,(unsigned long long)got,(unsigned long long)want);return 1;}
        queue_start(got);if (decode_error) return 1;
        memset(buffer.pcm,0xa5,sizeof(buffer.pcm));buffer.before=0x13579bdf;buffer.after=0x2468ace0;
        unsigned count=queue_read(buffer.pcm,256);uint64_t offset=got*rate/1000*8;
        if (count!=256 || offset+count*8>(uint64_t)bytes || memcmp(buffer.pcm,reference+offset,count*8) ||
            decode_error || buffer.before!=0x13579bdf || buffer.after!=0x2468ace0) {fprintf(stderr,"chapter PCM %u\n",i);return 1;}
        for (unsigned at=count*8;at<sizeof(buffer.pcm);at++) if (((unsigned char *)buffer.pcm)[at]!=0xa5) return 1;
        decoder_close();
    }
    free(reference);queue_target=0;
    printf("{\"boundaries\":%u,\"heard_file_seeks\":8,\"result\":\"exact PCM after decode ahead\",\"rate\":%u}\n",n,rate);
    return 0;
}
