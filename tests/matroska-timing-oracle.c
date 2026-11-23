/* Full shipping decoder: irregular reads, empty output and presentation seeks. */
#include "lamp-test.h"
LAMP_ABI int decoder_open(const lamp_char*);
LAMP_ABI void decoder_close(void);
LAMP_ABI unsigned decoder_read(float*,unsigned);
LAMP_ABI uint64_t decoder_seek(uint64_t);
extern unsigned decode_error,output_rate,source_channels,track_choice,track_active,track_cut_count;
extern uint64_t output_frames;
static struct{uint64_t before;float pcm[8192];uint64_t after;} out;
static uint64_t checks,words;
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"timing check failed line%d error%u\n",__LINE__,decode_error);exit(1);}}while(0)
static unsigned read_checked(unsigned n,const unsigned char*expected,uint64_t position,uint64_t frames){
 memset(out.pcm,0xa5,sizeof(out.pcm));out.before=0x125789abcdef0432ULL;out.after=0x97654321fedcba80ULL;unsigned got=decoder_read(out.pcm,n),want=frames-position<n?(unsigned)(frames-position):n;
 if(decode_error||got!=want)fprintf(stderr,"Read at %llu: wanted%u got%u error%u\n",(unsigned long long)position,want,got,decode_error);
 CHECK(!decode_error&&got==want);
 if(memcmp(out.pcm,expected+position*8,got*8))fprintf(stderr,"PCM differs at presented position %llu\n",(unsigned long long)position);
 CHECK(!memcmp(out.pcm,expected+position*8,got*8));words+=(uint64_t)got*2;CHECK(out.before==0x125789abcdef0432ULL&&out.after==0x97654321fedcba80ULL);for(unsigned i=got*8;i<sizeof(out.pcm);i++)CHECK(((unsigned char*)out.pcm)[i]==0xa5);return got;
}
int lamp_main(int argc,lamp_char**argv){
 if(argc==5&&!lamp_strcmp(argv[1],LT("--dump"))){CHECK(decoder_open(argv[2]));uint64_t target=lamp_strtou64(argv[3],NULL,10);CHECK(target<=output_frames);uint64_t base=decoder_seek(target);CHECK(base<=target&&!decode_error);while(base<target){unsigned n=target-base>4096?4096:(unsigned)(target-base);CHECK(decoder_read(out.pcm,n)==n&&!decode_error);base+=n;}FILE*f=lamp_fopen(argv[4],LT("wb"));CHECK(f);uint64_t written=0;for(unsigned calls=0;;calls++){CHECK(calls<100000);unsigned n=decoder_read(out.pcm,4096);CHECK(!decode_error&&fwrite(out.pcm,8,n,f)==n);written+=n;if(!n)break;}CHECK(written==output_frames-target);fclose(f);decoder_close();CHECK(!track_active&&!track_cut_count);return 0;}
 if(argc<6||argc>7)return 2;FILE*f=lamp_fopen(argv[2],LT("rb"));CHECK(f&&!fseek(f,0,SEEK_END));long bytes=ftell(f);CHECK(bytes>=0&&bytes%8==0);rewind(f);unsigned char*expected=malloc(bytes+1);CHECK(expected&&fread(expected,1,bytes,f)==(size_t)bytes);fclose(f);FILE*reset=argc==7?lamp_fopen(argv[6],LT("rb")):NULL;if(argc==7)CHECK(reset);uint64_t frames=(uint64_t)bytes/8;track_choice=(unsigned)lamp_atoi(argv[3]);unsigned rate=lamp_atoi(argv[4]),channels=lamp_atoi(argv[5]);CHECK(decoder_open(argv[1])&&output_frames==frames&&output_rate==rate&&source_channels==channels);uint64_t position=0;for(unsigned turn=0;;turn++){CHECK(turn<100000);unsigned n=read_checked(1+(turn*137)%4096,expected,position,frames);position+=n;if(!n)break;}CHECK(position==frames);decoder_close();CHECK(!track_active&&!track_cut_count);
 const uint64_t targets[]={0,1,2,17,119,120,511,512,4095,4096,frames/3,frames/2+1,frames?frames-1:0,frames,frames+1,UINT64_MAX};
 for(unsigned i=0;i<sizeof(targets)/sizeof(*targets);i++){
  uint64_t target=targets[i]>frames?frames:targets[i];unsigned char*tail=NULL;uint32_t tail_bytes=0;
  if(reset){uint64_t recorded;CHECK(fread(&recorded,8,1,reset)==1&&recorded==target&&fread(&tail_bytes,4,1,reset)==1&&tail_bytes%8==0);tail=malloc((size_t)tail_bytes+1);CHECK(tail&&fread(tail,1,tail_bytes,reset)==tail_bytes&&tail_bytes/8==frames-target);}
  CHECK(decoder_open(argv[1])&&output_frames==frames);uint64_t base=decoder_seek(targets[i]);CHECK(!decode_error&&base<=target);
  /* Seek pre-roll reconstructs codec history; callers discard these samples.
     Check counts/bounds here and exact user-visible PCM at the target below. */
  while(base<target){unsigned n=target-base>4096?4096:(unsigned)(target-base);out.before=1;out.after=2;memset(out.pcm,0xa5,sizeof(out.pcm));CHECK(decoder_read(out.pcm,n)==n&&!decode_error&&out.before==1&&out.after==2);for(unsigned j=n*8;j<sizeof(out.pcm);j++)CHECK(((unsigned char*)out.pcm)[j]==0xa5);base+=n;}
  if(reset)read_checked(1+(i*53)%4096,tail,0,tail_bytes/8);else read_checked(1+(i*53)%4096,expected,target,frames);
  free(tail);decoder_close();CHECK(!track_active&&!track_cut_count);
 }
 if(reset)fclose(reset);
 free(expected);printf("{\"result\":\"passed\",\"frames\":%llu,\"seeks\":16,\"checks\":%llu,\"exact_float_words\":%llu}\n",(unsigned long long)frames,(unsigned long long)checks,(unsigned long long)words);return 0;}
