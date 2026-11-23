/* Test-only packet boundaries against unmodified, pinned Xiph libvorbis.
   No granule trimming: every packet is measured before container clocks. */
#include "lamp-test.h"
#include <vorbis/codec.h>
#include <math.h>
LAMP_ABI int vorbis_track_open(const void *);
LAMP_ABI void vorbis_track_reset(void);
LAMP_ABI int vorbis_track_samples(const void *,unsigned);
LAMP_ABI int vorbis_track_decode(const void *,unsigned,float *,unsigned);
LAMP_ABI void vorbis_close(void);
extern unsigned decode_error;
typedef struct {unsigned char *data;uint64_t bytes;} Packet;
static Packet *packets;static unsigned count,checks;static uint64_t words,frames,transitions;
#define CHECK(x) do {checks++;if(!(x)){fprintf(stderr,"packet clock assertion line%d error%u\n",__LINE__,decode_error);return 1;}} while(0)
static ogg_packet packet(unsigned i){ogg_packet p={0};p.packet=packets[i].data;p.bytes=(long)packets[i].bytes;p.b_o_s=i==0;p.granulepos=-1;p.packetno=i;return p;}
int lamp_main(int argc,lamp_char **argv){
 if(argc!=2)return 2;FILE *f=lamp_fopen(argv[1],LT("rb"));CHECK(f&&fread(&count,4,1,f)==1&&count>4&&count<100000);
 packets=calloc(count,sizeof(*packets));CHECK(packets);
 for(unsigned i=0;i<count;i++){unsigned n;CHECK(fread(&n,4,1,f)==1&&n&&n<4000000);packets[i].bytes=n;packets[i].data=malloc(n);CHECK(packets[i].data&&fread(packets[i].data,n,1,f)==1);}CHECK(fgetc(f)==EOF);fclose(f);
 double error=0,signal=0,peak=0;unsigned starts[]={3,4,5,3+(count-3)/3,count-2,3};
 for(unsigned pass=0;pass<sizeof(starts)/sizeof(*starts);pass++){
  vorbis_info info;vorbis_comment comment;vorbis_dsp_state dsp;vorbis_block block;vorbis_info_init(&info);vorbis_comment_init(&comment);
  for(unsigned i=0;i<3;i++){ogg_packet p=packet(i);CHECK(!vorbis_synthesis_headerin(&info,&comment,&p));}
  CHECK(info.channels==1||info.channels==2);CHECK(!vorbis_synthesis_init(&dsp,&info)&&!vorbis_block_init(&dsp,&block));
  decode_error=0;CHECK(vorbis_track_open(packets));long previous=0;
  for(unsigned i=starts[pass];i<count;i++){
   ogg_packet p=packet(i);long size=vorbis_packet_blocksize(&info,&p);CHECK(size>=64&&size<=8192);unsigned expected=previous?(unsigned)(previous+size)/4:0;
   CHECK(vorbis_track_samples(p.packet,(unsigned)p.bytes)==(int)expected);if(previous&&size!=previous)transitions++;previous=size;
  }
  vorbis_track_reset();
  for(unsigned i=starts[pass];i<count;i++){
   ogg_packet p=packet(i);CHECK(!vorbis_synthesis(&block,&p)&&!vorbis_synthesis_blockin(&dsp,&block));float **pcm;int n=vorbis_synthesis_pcmout(&dsp,&pcm);CHECK(n>=0&&n<=4096);
   struct {uint64_t left;float pcm[8192];uint64_t right;} out;memset(&out,0xa5,sizeof(out));out.left=1;out.right=2;
   CHECK(vorbis_track_decode(p.packet,(unsigned)p.bytes,out.pcm,(unsigned)n)==n&&!decode_error&&out.left==1&&out.right==2);
   for(unsigned j=(unsigned)n*8;j<sizeof(out.pcm);j++)CHECK(((unsigned char*)out.pcm)[j]==0xa5);
   for(int j=0;j<n;j++)for(unsigned c=0;c<2;c++){float ref=pcm[c%info.channels][j],actual=out.pcm[j*2+c];CHECK(isfinite(actual));double d=(double)actual-ref;error+=d*d;signal+=(double)ref*ref;if(fabs(d)>peak)peak=fabs(d);words++;}
   frames+=n;CHECK(!vorbis_synthesis_read(&dsp,n));
  }
  vorbis_close();vorbis_block_clear(&block);vorbis_dsp_clear(&dsp);vorbis_comment_clear(&comment);vorbis_info_clear(&info);
 }
 CHECK(peak<=0.00002&&(error==0||signal/error>=1e8));
 /* Capacity failure must not write even when synthesis has retained PCM. */
 decode_error=0;CHECK(vorbis_track_open(packets));float guard[8192];memset(guard,0xa5,sizeof(guard));
 CHECK(vorbis_track_decode(packets[3].data,(unsigned)packets[3].bytes,guard,0)==0);
 CHECK(vorbis_track_decode(packets[4].data,(unsigned)packets[4].bytes,guard,0)==-1&&decode_error);
 for(unsigned i=0;i<sizeof(guard);i++)CHECK(((unsigned char*)guard)[i]==0xa5);vorbis_close();
 decode_error=0;CHECK(vorbis_track_open(packets));CHECK(vorbis_track_samples(packets[3].data,0)==-1);CHECK(vorbis_track_decode(packets[3].data,0,guard,4096)==-1&&decode_error);vorbis_close();
 for(unsigned i=0;i<count;i++)free(packets[i].data);free(packets);
 printf("{\"result\":\"passed\",\"packets\":%u,\"checks\":%u,\"frames\":%llu,\"float_words\":%llu,\"window_transitions\":%llu,\"peak_error\":%.10g,\"snr_db\":%.6f}\n",count-3,checks,(unsigned long long)frames,(unsigned long long)words,(unsigned long long)transitions,peak,error?10*log10(signal/error):300.0);return 0;
}
