/* Huge media gaps remain seekable without allocating gap-sized PCM. */
#include "lamp-test.h"
LAMP_ABI int decoder_open(const lamp_char*);
LAMP_ABI void decoder_close(void);
LAMP_ABI unsigned decoder_read(float*,unsigned);
LAMP_ABI uint64_t decoder_seek(uint64_t);
extern unsigned decode_error,track_time_active,track_time_event_count,track_time_span_count;
extern unsigned *ogg_cancel_ptr;
extern uint64_t output_frames;
static struct {uint64_t before;float pcm[16];uint64_t after;} out;
static unsigned checks;
#define CHECK(x) do {checks++;if(!(x)){fprintf(stderr,"sparse clock failed line%d error%u\n",__LINE__,decode_error);return 1;}} while(0)
int lamp_main(int argc,lamp_char**argv){
 if(argc!=3)return 2;uint64_t gap=lamp_strtou64(argv[2],NULL,10);CHECK(gap>4096&&gap<UINT64_MAX-4);
 CHECK(decoder_open(argv[1])&&!decode_error&&track_time_active&&output_frames==gap+4);
 memset(&out,0xa5,sizeof(out));out.before=1;out.after=2;CHECK(decoder_read(out.pcm,4)==4&&!decode_error);for(unsigned i=0;i<8;i++)CHECK(out.pcm[i]==0);CHECK(out.before==1&&out.after==2);
 CHECK(decoder_seek(gap-1)==gap-1&&!decode_error);memset(out.pcm,0xa5,sizeof(out.pcm));CHECK(decoder_read(out.pcm,5)==5&&!decode_error);CHECK(out.pcm[0]==0&&out.pcm[1]==0);
 for(unsigned i=1;i<=4;i++)CHECK(out.pcm[i*2]==(float)i/32768&&out.pcm[i*2+1]==-(float)i/32768);
 for(unsigned i=40;i<sizeof(out.pcm);i++)CHECK(((unsigned char*)out.pcm)[i]==0xa5);CHECK(!decoder_read(out.pcm,1)&&!decode_error);CHECK(out.before==1&&out.after==2);
 CHECK(decoder_seek(UINT64_MAX)==gap+4&&!decoder_read(out.pcm,1)&&!decode_error);CHECK(decoder_seek(0)==0);unsigned cancel=1;ogg_cancel_ptr=&cancel;CHECK(!decoder_seek(gap)&&!decode_error);CHECK(!decoder_read(out.pcm,1)&&decode_error==61);ogg_cancel_ptr=NULL;
 decoder_close();CHECK(!track_time_active&&!track_time_event_count&&!track_time_span_count);CHECK(decoder_open(argv[1])&&output_frames==gap+4);decoder_close();
 printf("{\"result\":\"passed\",\"gap_frames\":%llu,\"checks\":%u}\n",(unsigned long long)gap,checks);return 0;
}
