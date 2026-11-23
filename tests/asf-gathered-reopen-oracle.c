/* Alternate native-layout ASF PCM with ordinary container PCM in one process. */
#include "lamp-test.h"
LAMP_ABI int decoder_open(const lamp_char*);
LAMP_ABI void decoder_close(void);
LAMP_ABI uint64_t decoder_seek(uint64_t);
LAMP_ABI unsigned decoder_read(float*,unsigned);
extern unsigned decode_error,track_pcm_prepared,track_active,track_time_active;
extern uint64_t output_frames;
#define CHECK(x) do{if(!(x)){fprintf(stderr,"ASF reopen line%d error%u\n",__LINE__,decode_error);return 1;}}while(0)
int lamp_main(int argc,lamp_char**argv){
 if(argc!=5)return 2;struct{uint64_t a;float pcm[2048];uint64_t b;}out;unsigned checks=0;
 for(unsigned turn=0;turn<12;turn++){
  unsigned choice=(turn+turn/3)%2;FILE*f=lamp_fopen(argv[2+choice*2],LT("rb"));CHECK(f&&!fseek(f,0,SEEK_END));long bytes=ftell(f);CHECK(bytes>=0&&bytes%8==0);rewind(f);unsigned char*expected=malloc(bytes+1);CHECK(expected&&fread(expected,1,bytes,f)==(size_t)bytes&&!fclose(f));CHECK(decoder_open(argv[1+choice*2])&&!decode_error&&output_frames==bytes/8);
  uint64_t target=turn%3==0?0:17;if(target>output_frames)target=output_frames;uint64_t base=decoder_seek(target);CHECK(base<=target&&!decode_error);while(base<target){unsigned n=target-base>1024?1024:(unsigned)(target-base);CHECK(decoder_read(out.pcm,n)==n&&!decode_error);base+=n;}uint64_t at=target;
  for(;;){out.a=123;out.b=456;memset(out.pcm,0xa5,sizeof(out.pcm));unsigned n=decoder_read(out.pcm,719);CHECK(!decode_error&&n<=719&&out.a==123&&out.b==456&&at+n<=output_frames&&!memcmp(out.pcm,expected+at*8,n*8));for(unsigned i=n*8;i<sizeof(out.pcm);i++)CHECK(((unsigned char*)out.pcm)[i]==0xa5);at+=n;if(!n)break;}
  CHECK(at==output_frames);decoder_close();CHECK(!track_pcm_prepared&&!track_active&&!track_time_active);free(expected);checks++;
 }
 printf("{\"result\":\"passed\",\"alternating_reopens\":%u}\n",checks);return 0;
}
