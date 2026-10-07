/* Compare container seeks with seeks in the exact gathered audio stream.
   AC-3 dither restarts at a seek; both paths must still produce identical PCM. */
#include "lamp-test.h"
LAMP_ABI int decoder_open(const lamp_char *);
LAMP_ABI void decoder_close(void);
LAMP_ABI uint64_t decoder_seek(uint64_t);
LAMP_ABI unsigned decoder_read(float *,unsigned);
extern unsigned track_choice,decode_error,output_rate;
extern uint64_t output_frames;
static int portion(const lamp_char *path,unsigned choice,uint64_t target,float *output,unsigned *frames) {
    track_choice=choice;if(!decoder_open(path))return 0;
    uint64_t end=output_frames;if(target>end)target=end;
    uint64_t base=decoder_seek(target);float scratch[4096];
    if(base>target||decode_error)return 0;
    while(base<target){unsigned wanted=target-base>2048?2048:(unsigned)(target-base);
        unsigned n=decoder_read(scratch,wanted);if(n!=wanted||decode_error)return 0;base+=n;}
    *frames=decoder_read(output,1024);int ok=!decode_error;decoder_close();return ok;
}
int lamp_main(int argc,lamp_char **argv) {
    if(argc!=4)return 2;unsigned choice=lamp_atoi(argv[3]);track_choice=choice;
    if(!decoder_open(argv[1])||!output_frames)return 1;
    uint64_t total=output_frames;unsigned rate=output_rate;decoder_close();
    track_choice=0;if(!decoder_open(argv[2])||output_frames!=total||output_rate!=rate)return 1;decoder_close();
    uint64_t requests[]={0,1,119,120,4095,4096,4607,4608,9215,9216,total/2+17,total-1,total,total+1,UINT64_MAX};
    float a[2048],b[2048];unsigned checks=0;
    for(unsigned i=0;i<sizeof(requests)/sizeof(*requests);i++){
        unsigned na=0,nb=0;
        if(!portion(argv[1],choice,requests[i],a,&na)||!portion(argv[2],0,requests[i],b,&nb)||
           na!=nb||memcmp(a,b,na*8)){fprintf(stderr,"Container/raw seek mismatch %u\n",i);return 1;}checks++;
    }
    printf("{\"result\":\"passed\",\"exact_cold_seeks\":%u,\"frames\":%llu}\n",checks,(unsigned long long)total);return 0;
}
