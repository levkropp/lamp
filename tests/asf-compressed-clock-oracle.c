/* Bounded reads/seeks across compressed-object timestamp accumulation. */
#include "lamp-test.h"
LAMP_ABI int decoder_open(const lamp_char*);
LAMP_ABI void decoder_close(void);
LAMP_ABI unsigned decoder_read(float*,unsigned);
LAMP_ABI uint64_t decoder_seek(uint64_t);
extern unsigned decode_error,track_time_active;
extern uint64_t output_frames;
#define CHECK(x) do{if(!(x)){fprintf(stderr,"ASF compressed clock line%d error%u\n",__LINE__,decode_error);return 1;}}while(0)
int lamp_main(int argc,lamp_char**argv){
 if(argc!=4)return 2;uint64_t target=lamp_strtou64(argv[3],NULL,10);FILE*f=lamp_fopen(argv[2],LT("rb"));CHECK(f&&!fseek(f,0,SEEK_END));long bytes=ftell(f);CHECK(bytes>0&&bytes<=32768&&bytes%8==0);rewind(f);unsigned char*expected=malloc(bytes);CHECK(expected&&fread(expected,1,bytes,f)==(size_t)bytes);fclose(f);
 CHECK(decoder_open(argv[1])&&!decode_error&&track_time_active&&output_frames==target+bytes/8);struct{uint64_t a;float pcm[8194];uint64_t b;}out;out.a=1;out.b=2;CHECK(decoder_read(out.pcm,4)==4&&!decode_error);for(unsigned i=0;i<8;i++)CHECK(!out.pcm[i]);
 CHECK(decoder_seek(target-1)==target-1&&!decode_error);CHECK(decoder_read(out.pcm,1+bytes/8)==1+bytes/8&&!decode_error);CHECK(!out.pcm[0]&&!out.pcm[1]&&!memcmp(out.pcm+2,expected,bytes));CHECK(out.a==1&&out.b==2&&!decoder_read(out.pcm,1)&&!decode_error);CHECK(decoder_seek(UINT64_MAX)==output_frames&&!decoder_read(out.pcm,1));decoder_close();CHECK(!track_time_active);free(expected);puts("{\"result\":\"passed\",\"bounded_tail_seek\":true}");return 0;
}
