/* Signed millisecond boundary/extended timestamp checks, bounded gap reads. */
#include "lamp-test.h"
LAMP_ABI int decoder_open(const lamp_char*);
LAMP_ABI void decoder_close(void);
LAMP_ABI unsigned decoder_read(float*,unsigned);
LAMP_ABI uint64_t decoder_seek(uint64_t);
extern unsigned decode_error,track_time_active,track_time_event_count,track_time_span_count;
extern unsigned *ogg_cancel_ptr;
extern uint64_t output_frames;
static unsigned checks;
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"FLV sparse assertion line%d error%u\n",__LINE__,decode_error);return 1;}}while(0)
int lamp_main(int argc,lamp_char**argv){
 if(argc!=4&&argc!=5)return 2;uint64_t gap=lamp_strtou64(argv[3],NULL,10);unsigned prefix=argc==5?lamp_atoi(argv[4]):0;FILE*f=lamp_fopen(argv[2],LT("rb"));CHECK(f&&!fseek(f,0,SEEK_END));long bytes=ftell(f);CHECK(bytes>0&&bytes%8==0&&bytes<=32768&&prefix<(unsigned)bytes/8);rewind(f);unsigned char *reference=malloc(bytes);CHECK(reference&&fread(reference,1,bytes,f)==(size_t)bytes);fclose(f);
 CHECK(decoder_open(argv[1])&&!decode_error&&track_time_active&&output_frames==gap+bytes/8);struct{uint64_t a;float pcm[8194];uint64_t b;} out;out.a=1;out.b=2;memset(out.pcm,0xa5,sizeof(out.pcm));if(prefix)CHECK(decoder_read(out.pcm,prefix)==prefix&&!memcmp(out.pcm,reference,prefix*8)&&!decode_error);CHECK(decoder_read(out.pcm,4)==4&&!decode_error);for(unsigned i=0;i<8;i++)CHECK(!out.pcm[i]);CHECK(out.a==1&&out.b==2);
 CHECK(decoder_seek(gap+prefix-1)==gap+prefix-1&&!decode_error);CHECK(decoder_read(out.pcm,1+bytes/8-prefix)==1+bytes/8-prefix&&!decode_error);CHECK(!out.pcm[0]&&!out.pcm[1]&&!memcmp(out.pcm+2,reference+prefix*8,bytes-prefix*8));CHECK(!decoder_read(out.pcm,1)&&!decode_error&&out.a==1&&out.b==2);CHECK(decoder_seek(UINT64_MAX)==gap+bytes/8&&!decoder_read(out.pcm,1));
 CHECK(decoder_seek(0)==0);unsigned cancel=1;ogg_cancel_ptr=&cancel;CHECK(!decoder_seek(gap)&&!decode_error);CHECK(!decoder_read(out.pcm,1)&&decode_error==61);ogg_cancel_ptr=NULL;decoder_close();CHECK(!track_time_active&&!track_time_event_count&&!track_time_span_count);CHECK(decoder_open(argv[1])&&output_frames==gap+bytes/8);decoder_close();free(reference);
 printf("{\"result\":\"passed\",\"gap_frames\":%llu,\"checks\":%u}\n",(unsigned long long)gap,checks);return 0;
}
