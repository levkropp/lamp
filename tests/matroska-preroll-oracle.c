/* Test-only public decoder seeks against independently prepared restarts. */
#include "lamp-test.h"
LAMP_ABI int decoder_open(const lamp_char*);
LAMP_ABI void decoder_close(void);
LAMP_ABI unsigned decoder_read(float*,unsigned);
LAMP_ABI uint64_t decoder_seek(uint64_t);
extern unsigned decode_error,output_rate,source_channels,track_choice,track_active,track_cut_count;
extern uint64_t output_frames,track_seek_preroll_ns;
extern unsigned *ogg_cancel_ptr;
static struct {uint64_t before;float pcm[8192];uint64_t after;} out;
static uint64_t checks,words,seeks;
#define CHECK(x) do {checks++;if(!(x)){fprintf(stderr,"pre-roll check failed line%d error%u\n",__LINE__,decode_error);exit(1);}} while(0)
static uint64_t u64(FILE*f){uint64_t n;CHECK(fread(&n,8,1,f)==1);return n;}
static unsigned u32(FILE*f){unsigned n;CHECK(fread(&n,4,1,f)==1);return n;}
static unsigned read_pcm(unsigned n){
 CHECK(n<=4096);memset(out.pcm,0xa5,sizeof(out.pcm));out.before=0x178954321abcdeffULL;out.after=0x914378921abcdef0ULL;
 unsigned got=decoder_read(out.pcm,n);CHECK(!decode_error&&got<=n&&out.before==0x178954321abcdeffULL&&out.after==0x914378921abcdef0ULL);
 for(unsigned i=got*8;i<sizeof(out.pcm);i++)CHECK(((unsigned char*)out.pcm)[i]==0xa5);return got;
}
static void close_checked(void){decoder_close();CHECK(!track_active&&!track_cut_count&&!track_seek_preroll_ns);}
int lamp_main(int argc,lamp_char**argv){
 if(argc!=6)return 2;FILE*f=lamp_fopen(argv[2],LT("rb"));CHECK(f);CHECK(!fseek(f,0,SEEK_END));long bytes=ftell(f);CHECK(bytes>=0&&bytes%8==0);rewind(f);unsigned char*pcm=malloc(bytes+1);CHECK(pcm&&fread(pcm,1,bytes,f)==(size_t)bytes);fclose(f);
 FILE*model=lamp_fopen(argv[3],LT("rb"));CHECK(model);uint64_t ns=u64(model);unsigned rate=u32(model),channels=u32(model),count=u32(model);uint64_t frames=(uint64_t)bytes/8;track_choice=(unsigned)lamp_atoi(argv[4]);
 CHECK(decoder_open(argv[1])&&output_frames==frames&&output_rate==rate&&source_channels==channels&&track_seek_preroll_ns==ns);
 uint64_t at=0;for(unsigned turn=0;;turn++){CHECK(turn<1000000);unsigned request=1+turn*137%4096,n=read_pcm(request);CHECK(n==(frames-at<request?(unsigned)(frames-at):request));CHECK(!memcmp(out.pcm,pcm+at*8,n*8));words+=(uint64_t)n*2;at+=n;if(!n)break;}CHECK(at==frames);close_checked();
 /* Repeated seeks on one open also exercise rewind-to-zero after EOF. */
 CHECK(decoder_open(argv[1])&&output_frames==frames&&track_seek_preroll_ns==ns);
 for(unsigned i=0;i<count;i++){
  uint64_t request=u64(model),expected_base=u64(model),target=u64(model);unsigned wanted=u32(model);CHECK(wanted<=4096&&target<=frames&&wanted<=frames-target);unsigned char expected[32768];CHECK(fread(expected,8,wanted,model)==wanted);
  uint64_t base=decoder_seek(request);if(base!=expected_base)fprintf(stderr,"request%llu: resume%llu expected%llu\n",(unsigned long long)request,(unsigned long long)base,(unsigned long long)expected_base);CHECK(!decode_error&&base==expected_base&&base<=target);
  while(base<target){unsigned n=target-base>4096?4096:(unsigned)(target-base);CHECK(read_pcm(n)==n);base+=n;}
  CHECK(read_pcm(wanted?4096:1)==wanted);if(memcmp(out.pcm,expected,wanted*8))fprintf(stderr,"seek PCM differs request%llu\n",(unsigned long long)request);CHECK(!memcmp(out.pcm,expected,wanted*8));words+=(uint64_t)wanted*2;seeks++;
 }
 CHECK(fgetc(model)==EOF);fclose(model);close_checked();
 /* Pre-cancelled seek must not disturb the decoder, and close clears timing. */
 CHECK(decoder_open(argv[1]));unsigned cancel=1;ogg_cancel_ptr=&cancel;CHECK(!decoder_seek(UINT64_MAX)&&!decode_error);ogg_cancel_ptr=NULL;CHECK(read_pcm(1)==(frames?1u:0u));if(frames)CHECK(!memcmp(out.pcm,pcm,8));close_checked();
 track_choice=0;CHECK(decoder_open(argv[5])&&!track_seek_preroll_ns);close_checked();free(pcm);
 printf("{\"result\":\"passed\",\"seeks\":%llu,\"checks\":%llu,\"exact_float_words\":%llu}\n",(unsigned long long)seeks,(unsigned long long)checks,(unsigned long long)words);return 0;
}
