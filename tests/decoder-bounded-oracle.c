/* Test-only mutation playback: bounded work even for valid multi-year gaps.
   Ordinary short inputs still decode through EOF; long timelines also seek
   to their midpoint. Test bounds are not playback/runtime format limits. */
#include "lamp-test.h"
#include <math.h>
LAMP_ABI int decoder_open(const lamp_char*);
LAMP_ABI void decoder_close(void);
LAMP_ABI uint64_t decoder_seek(uint64_t);
LAMP_ABI unsigned decoder_read(float*,unsigned);
extern uint64_t output_frames;
extern unsigned output_rate,decode_error,track_active,track_time_active,track_pcm_prepared;
static struct{uint64_t a;float pcm[4096];uint64_t b;}out;
int lamp_main(int argc,lamp_char**argv){
 if(argc!=2&&argc!=3)return 1;unsigned calls=0;uint64_t frames=0;int opened=decoder_open(argv[1]);
 if(opened&&argc==3){uint64_t micros=lamp_strtou64(argv[2],NULL,10);if(micros>1000000)return 1;uint64_t target=(micros*output_rate+500000)/1000000;if(target>output_frames)target=output_frames;uint64_t base=decoder_seek(target);if(base>target) return 1;while(base<target&&!decode_error){unsigned n=target-base>2048?2048:(unsigned)(target-base);if(decoder_read(out.pcm,n)!=n&&!decode_error)return 1;base+=n;}}
 if(opened)for(;calls<256;calls++){
  if(calls==128)decoder_seek(output_frames/2);
  out.a=0x12345678;out.b=0x76543210;memset(out.pcm,0xa5,sizeof(out.pcm));unsigned n=decoder_read(out.pcm,2048);
  if(n>2048||out.a!=0x12345678||out.b!=0x76543210)return 1;
  for(unsigned i=n*8;i<sizeof(out.pcm);i++)if(((unsigned char*)out.pcm)[i]!=0xa5)return 1;
  if(!decode_error)for(unsigned i=0;i<n*2;i++)if(!isfinite(out.pcm[i]))return 1;
  frames+=n;if(!n||decode_error)break;
 }
 unsigned error=decode_error;decoder_close();if(track_active||track_time_active||track_pcm_prepared)return 1;
 printf("{\"opened\":%s,\"read_calls\":%u,\"frames\":%llu,\"decode_error\":%u}\n",opened?"true":"false",calls,(unsigned long long)frames,error);return error||!opened?2:0;
}
