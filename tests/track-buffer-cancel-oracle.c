/* Cancel after a one-frame read has left a decoded PCM packet buffered. */
#include "lamp-test.h"
LAMP_ABI int decoder_open(const lamp_char*);
LAMP_ABI void decoder_close(void);
LAMP_ABI unsigned decoder_read(float*,unsigned);
extern unsigned decode_error,track_active,track_time_active;
extern unsigned *ogg_cancel_ptr;
extern uint64_t output_frames;
#define CHECK(x) do{if(!(x)){fprintf(stderr,"buffered cancel line%d error%u\n",__LINE__,decode_error);return 1;}}while(0)
int lamp_main(int argc,lamp_char**argv){
 if(argc!=2)return 2;CHECK(decoder_open(argv[1])&&track_active&&!track_time_active&&!decode_error&&output_frames>2);uint64_t frames=output_frames;float first[2];CHECK(decoder_read(first,1)==1&&!decode_error);
 struct{uint64_t a;float pcm[2];uint64_t b;}out;memset(&out,0xa5,sizeof(out));unsigned cancel=1;ogg_cancel_ptr=&cancel;CHECK(!decoder_read(out.pcm,1)&&decode_error==61);for(unsigned i=0;i<sizeof(out);i++)CHECK(((unsigned char*)&out)[i]==0xa5);ogg_cancel_ptr=NULL;decoder_close();CHECK(!track_active&&!track_time_active);
 CHECK(decoder_open(argv[1])&&!decode_error&&output_frames==frames);CHECK(decoder_read(out.pcm,1)==1&&!memcmp(first,out.pcm,8));decoder_close();CHECK(!track_active&&!track_time_active);puts("{\"result\":\"passed\",\"cancelled_before_buffered_copy\":true,\"reopened\":true}");return 0;
}
