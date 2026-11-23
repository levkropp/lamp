/* Test-only source PCM export, explicitly excluding the media clock.
   Separates codec/cut reference generation from timestamp presentation. */
#include "lamp-test.h"
LAMP_ABI int decoder_open(const lamp_char*);
LAMP_ABI void decoder_close(void);
LAMP_ABI uint64_t decoder_seek(uint64_t);
LAMP_ABI unsigned decoder_read(float*,unsigned);
LAMP_ABI void track_time_close(void);
extern unsigned track_active,track_time_active,decode_error;
extern uint64_t total_frames,output_frames,track_time_source_frames;
static float pcm[8192];
#define CHECK(x) do {if(!(x)){fprintf(stderr,"source export failed line%d error%u\n",__LINE__,decode_error);return 1;}} while(0)
int lamp_main(int argc,lamp_char**argv){
 if(argc!=4)return 2;
 CHECK(decoder_open(argv[1])&&track_active&&!decode_error);
 uint64_t source_frames=track_time_active?track_time_source_frames:output_frames;
 track_time_close();total_frames=output_frames=source_frames;
 /* The packet decoder still applies its original codec delay and cuts.
    Neutral references use headers/configuration with those explicitly removed. */
 CHECK(decoder_seek(0)==0&&!decode_error);
 uint64_t target=lamp_strtou64(argv[2],NULL,10);if(target>source_frames)target=source_frames;
 uint64_t base=decoder_seek(target);CHECK(base<=target&&!decode_error);
 while(base<target){unsigned n=target-base>4096?4096:(unsigned)(target-base);CHECK(decoder_read(pcm,n)==n&&!decode_error);base+=n;}
 FILE*f=lamp_fopen(argv[3],LT("wb"));CHECK(f);uint64_t frames=0;
 for(unsigned calls=0;;calls++){CHECK(calls<10000000);unsigned n=decoder_read(pcm,4096);CHECK(!decode_error&&fwrite(pcm,8,n,f)==n);frames+=n;if(!n)break;}
 CHECK(!fclose(f)&&frames==source_frames-target);decoder_close();CHECK(!track_active&&!track_time_active);
 printf("{\"result\":\"passed\",\"source_frames\":%llu,\"target\":%llu,\"exported_frames\":%llu}\n",(unsigned long long)source_frames,(unsigned long long)target,(unsigned long long)frames);return 0;
}
