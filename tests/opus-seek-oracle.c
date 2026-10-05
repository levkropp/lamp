/* Test-only independent Ogg packet reader and RFC8251 native seek reference.
   Runtime decoder objects are assembly. Reference C remains test-only. */
#include "lamp-test.h"
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <math.h>
#include "celt.c"
#undef MAX_PULSES
#include "opus_decoder.c"
LAMP_ABI int decoder_open(const lamp_char *);
LAMP_ABI void decoder_close(void);
LAMP_ABI uint64_t decoder_seek(uint64_t);
LAMP_ABI unsigned decoder_read(float *,unsigned);
extern unsigned decode_error,codec_kind,opus_index_count;
extern uint64_t total_frames,opus_index_stride,opus_seek_headers,opus_seek_raw;
extern unsigned *ogg_cancel_ptr;
typedef struct {unsigned char *data;unsigned bytes,samples;uint64_t raw;} Packet;
static Packet *packets;
static unsigned packet_count,channels,skip;
static unsigned configurations,framing_codes,dtx_packets;
static int gain;
static uint64_t raw_end,frames;
static float factor;
static struct {uint64_t before;float pcm[4096];uint64_t after;} out;
static uint64_t u64(const unsigned char *p){uint64_t v=0;for(unsigned j=0;j<8;j++)v|=(uint64_t)p[j]<<(8*j);return v;}
static int parse(const lamp_char *path){
 FILE *file=lamp_fopen(path,LT("rb"));if(!file||fseek(file,0,SEEK_END))return 0;
 long bytes=ftell(file);if(bytes<27||bytes>64*1024*1024)return 0;rewind(file);
 unsigned char *data=malloc(bytes),*partial=malloc(4*1024*1024);packets=calloc(131072,sizeof(*packets));
 if(!data||!partial||!packets||fread(data,1,bytes,file)!=(size_t)bytes)return 0;fclose(file);
 unsigned length=0,headers=0;uint64_t raw=0,origin=0;int anchored=0,eos=0;
 for(size_t at=0;at<(size_t)bytes;){
  if((size_t)bytes-at<27||memcmp(data+at,"OggS",4))return 0;
  unsigned count=data[at+26];size_t body=at+27+count;if(body>(size_t)bytes)return 0;int completed=0;
  for(unsigned j=0;j<count;j++){
   unsigned n=data[at+27+j];if(body+n>(size_t)bytes||length+n>4*1024*1024)return 0;
   memcpy(partial+length,data+body,n);length+=n;body+=n;if(n==255)continue;
   if(headers==0){if(length<19||memcmp(partial,"OpusHead",8))return 0;channels=partial[9];skip=partial[10]|partial[11]<<8;gain=(int16_t)(partial[16]|partial[17]<<8);headers++;}
   else if(headers==1){if(length<16||memcmp(partial,"OpusTags",8))return 0;headers++;}
   else {
    if(packet_count>=131072)return 0;Packet *p=packets+packet_count++;
    p->data=malloc(length);p->bytes=length;p->raw=raw;if(!p->data)return 0;memcpy(p->data,partial,length);
    const unsigned char *parts[48];short sizes[48];unsigned char toc;int count=opus_packet_parse(p->data,p->bytes,&toc,parts,sizes,NULL),samples=count>0?count*opus_packet_get_samples_per_frame(p->data,48000):0;if(samples<=0||samples>5760)return 0;
    configurations|=1U<<(toc>>3);framing_codes|=1U<<(toc&3);int dtx=1;for(int f=0;f<count;f++)if(sizes[f]>1)dtx=0;dtx_packets+=dtx;p->samples=samples;raw+=samples;completed=1;
   }length=0;
  }
  if(completed){
   uint64_t gp=u64(data+at+6);if(gp>INT64_MAX)return 0;
   if(!anchored){if(gp<raw&&!(data[at+5]&4))return 0;origin=gp<raw?0:gp-raw;anchored=1;}
   if(data[at+5]&4){if(gp<origin||gp-origin>raw)return 0;raw_end=gp-origin;eos=1;}
   else if(gp!=raw+origin)return 0;
  }at=body;
 }
 free(data);free(partial);if(length||!eos||skip>raw_end||channels<1||channels>2)return 0;
 frames=raw_end-skip;factor=(float)pow(10.,gain/(20.*256.));return frames<32*1024*1024;
}
static int reference_window(OpusDecoder *state,unsigned start,uint64_t target,float *pcm,unsigned count){
 if(opus_decoder_init(state,48000,channels))return 0;unsigned emitted=0;float packet[11520];
 for(unsigned p=start;p<packet_count&&emitted<count;p++){
  int n=opus_decode_float(state,packets[p].data,packets[p].bytes,packet,5760,0);if(n!=(int)packets[p].samples)return 0;
  for(unsigned i=0;i<(unsigned)n&&emitted<count;i++)if(packets[p].raw+i>=target){for(unsigned c=0;c<2;c++)pcm[emitted*2+c]=packet[i*channels+(channels==1?0:c)]*factor;emitted++;}
 }return emitted==count;
}
static int equal(const float *a,const float *b,unsigned count,float *maximum){
 for(unsigned i=0;i<count;i++){float scale=fmaxf(1.f,fabsf(b[i])),error=fabsf(a[i]-b[i])/scale;if(!isfinite(a[i])||!isfinite(b[i])||error>0.00004f){fprintf(stderr,"Reference PCM[%u] %.9g/%.9g error%.9g\n",i,a[i],b[i],error);return 0;}if(error>*maximum)*maximum=error;}return 1;
}
static int write_page(FILE *file,const unsigned char *data,unsigned bytes,uint64_t gp,unsigned flags,unsigned sequence){
 unsigned char page[4096]={0};unsigned laces=bytes/255+1,length=27+laces+bytes;if(length>sizeof(page))return 0;
 memcpy(page,"OggS",4);page[5]=(unsigned char)flags;for(unsigned j=0;j<8;j++)page[6+j]=(unsigned char)(gp>>(8*j));
 for(unsigned j=0;j<4;j++){page[14+j]=(unsigned char)(0x504d414cU>>(8*j));page[18+j]=(unsigned char)(sequence>>(8*j));}page[26]=(unsigned char)laces;
 for(unsigned j=0;j<laces;j++)page[27+j]=(unsigned char)(j+1<laces?255:bytes%255);memcpy(page+27+laces,data,bytes);
 uint32_t crc=0;for(unsigned i=0;i<length;i++){crc^=(uint32_t)page[i]<<24;for(unsigned j=0;j<8;j++)crc=(crc<<1)^((crc&0x80000000)?0x04c11db7:0);}for(unsigned j=0;j<4;j++)page[22+j]=(unsigned char)(crc>>(8*j));
 return fwrite(page,1,length,file)==length;
}
static int generate(const lamp_char *directory){
 const int bands[]={OPUS_BANDWIDTH_NARROWBAND,OPUS_BANDWIDTH_WIDEBAND,OPUS_BANDWIDTH_SUPERWIDEBAND,OPUS_BANDWIDTH_FULLBAND};unsigned random=0x94751;
 for(unsigned config=0;config<34;config++)for(unsigned channels=1;channels<=2;channels++){
  lamp_char path[1024];lamp_snprintf(path,1024,LT("%s/seek-opus-native-%02u-%u.opus"),directory,config,channels);FILE *file=lamp_fopen(path,LT("wb"));if(!file)return 0;
  unsigned char head[19]={0},tags[16]={0},packet[2048];memcpy(head,"OpusHead",8);head[8]=1;head[9]=(unsigned char)channels;head[10]=56;head[11]=1;head[12]=128;head[13]=187;memcpy(tags,"OpusTags",8);
  if(!write_page(file,head,19,0,2,0)||!write_page(file,tags,16,0,0,1))return 0;
  OpusEncoder *enc=opus_encoder_create(48000,channels,OPUS_APPLICATION_AUDIO,NULL);if(!enc)return 0;unsigned sequence=2;uint64_t raw=0;float input[5760];
  for(unsigned p=0;raw<180000;p++){
   unsigned c=config<32?config:config==32?(p/11*7)%32:1;
   int mode=c<12?MODE_SILK_ONLY:c<16?MODE_HYBRID:MODE_CELT_ONLY;
   int bandwidth=c<12?OPUS_BANDWIDTH_NARROWBAND+c/4:c<16?OPUS_BANDWIDTH_SUPERWIDEBAND+(c-12)/2:bands[(c-16)/4];
   unsigned char toc=(unsigned char)(c<<3);int n=opus_packet_get_samples_per_frame(&toc,48000);
   opus_encoder_ctl(enc,OPUS_SET_FORCE_MODE(mode));opus_encoder_ctl(enc,OPUS_SET_BANDWIDTH(bandwidth));opus_encoder_ctl(enc,OPUS_SET_FORCE_CHANNELS(config==32?1+p/17%channels:channels));opus_encoder_ctl(enc,OPUS_SET_BITRATE(mode==MODE_CELT_ONLY?128000:48000));opus_encoder_ctl(enc,OPUS_SET_DTX(config==33));opus_encoder_ctl(enc,OPUS_SET_INBAND_FEC(1));opus_encoder_ctl(enc,OPUS_SET_PACKET_LOSS_PERC(20));
   for(int i=0;i<n;i++)for(unsigned channel=0;channel<channels;channel++){random=random*1664525+1013904223;float noise=((int)(random>>8)-8388608)/8388608.f;input[i*channels+channel]=config==33&&p%150<110?0.f:(float)(.17*sin((raw+i)*2*3.141592653589793*(113+79*channel)/48000)+.05*noise);}
   int bytes=opus_encode_float(enc,input,n,packet,sizeof(packet));if(bytes<=0)return 0;raw+=n;
   if(!write_page(file,packet,bytes,raw-(raw>=180000?17:0),raw>=180000?4:0,sequence++))return 0;
  }opus_encoder_destroy(enc);fclose(file);
 }return 1;
}
int lamp_main(int argc,lamp_char **argv){
 if(argc==3&&!lamp_strcmp(argv[1],LT("--generate")))return generate(argv[2])?0:1;
 if(argc!=2||!parse(argv[1]))return 2;
 OpusDecoder *state=opus_decoder_create(48000,channels,NULL);if(!state)return 2;
 float *continuous=malloc((size_t)(frames?frames:1)*8),packet[11520];if(!continuous)return 2;
 for(unsigned p=0;p<packet_count;p++){
  int n=opus_decode_float(state,packets[p].data,packets[p].bytes,packet,5760,0);if(n!=(int)packets[p].samples)return 1;
  for(unsigned i=0;i<(unsigned)n;i++){uint64_t raw=packets[p].raw+i;if(raw>=skip&&raw<raw_end)for(unsigned c=0;c<2;c++)continuous[(raw-skip)*2+c]=packet[i*channels+(channels==1?0:c)]*factor;}
 }
 float maximum=0,continuous_seek_max=0,continuous_max=0;uint64_t continuous_values=0;
 if(!decoder_open(argv[1])||codec_kind!=5||total_frames!=frames)return 1;
 for(uint64_t at=0;at<frames;){unsigned cap=frames-at>2048?2048:(unsigned)(frames-at),n=decoder_read(out.pcm,cap);if(n!=cap||decode_error||!equal(out.pcm,continuous+at*2,n*2,&continuous_max))return 1;at+=n;continuous_values+=(uint64_t)n*2;}
 if(decoder_read(out.pcm,1)||decode_error)return 1;decoder_close();
 uint64_t requests[64]={0,1,119,120,3839,3840,3841,4095,4096,4607,4608,9215,9216,frames/2+17,frames?frames-1:0,frames,frames+1,UINT64_MAX};unsigned request_count=18;
 for(unsigned p=1;p<packet_count&&request_count<32;p+=packet_count/13+1){uint64_t pos=packets[p].raw>skip?packets[p].raw-skip:0;requests[request_count++]=pos;requests[request_count++]=pos+1;}
 unsigned random=0x75319;for(unsigned i=0;i<16;i++){random=random*1664525+1013904223;requests[request_count++]=frames?random%frames:0;}
 unsigned checks=0,advanced=0,most_points=0;uint64_t most_headers=0,most_discarded=0,most_stride=0;float reference[4096];
 for(unsigned q=0;q<request_count;q++){
  uint64_t target=requests[q]>frames?frames:requests[q],raw_target=target+skip,want=target<3840?0:raw_target-3840;unsigned start=0;
  if(target>=3840)while(start+1<packet_count&&packets[start+1].raw<=want)start++;
  uint64_t expected_raw=packets[start].raw,expected_base=expected_raw>skip?expected_raw-skip:0;
  if(!decoder_open(argv[1])||total_frames!=frames||!opus_index_count||opus_index_count>2048)return 1;
  uint64_t base=decoder_seek(requests[q]);
  if(decode_error||base!=expected_base||opus_seek_raw!=expected_raw||opus_seek_headers>=opus_index_stride||target-base>9600){fprintf(stderr,"Seek position/work case%u base%llu/%llu raw%llu/%llu headers%llu stride%llu error%u\n",q,base,expected_base,opus_seek_raw,expected_raw,opus_seek_headers,opus_index_stride,decode_error);return 1;}
  if(target>=3840&&raw_target-expected_raw<3840)return 1;
  if(base)advanced++;if(opus_index_count>most_points)most_points=opus_index_count;if(opus_index_stride>most_stride)most_stride=opus_index_stride;if(opus_seek_headers>most_headers)most_headers=opus_seek_headers;if(target-base>most_discarded)most_discarded=target-base;
  while(base<target){unsigned cap=target-base>2048?2048:(unsigned)(target-base);if(decoder_read(out.pcm,cap)!=cap||decode_error)return 1;base+=cap;}
  out.before=0x13579bdf98765432ULL;out.after=0x2468ace012345678ULL;memset(out.pcm,0xa5,sizeof(out.pcm));
  unsigned cap=q*37%2048+1,wanted=frames-target<cap?(unsigned)(frames-target):cap,n=decoder_read(out.pcm,cap);
  if(n!=wanted||decode_error||out.before!=0x13579bdf98765432ULL||out.after!=0x2468ace012345678ULL||!reference_window(state,start,raw_target,reference,n)||!equal(out.pcm,reference,n*2,&maximum)){fprintf(stderr,"Seek PCM case%u at%llu\n",q,target);return 1;}
  for(unsigned i=0;i<n*2;i++){float scale=fmaxf(1.f,fabsf(continuous[target*2+i])),error=fabsf(out.pcm[i]-continuous[target*2+i])/scale;if(error>continuous_seek_max)continuous_seek_max=error;}
  for(unsigned i=n*8;i<sizeof(out.pcm);i++)if(((unsigned char *)out.pcm)[i]!=0xa5)return 1;
  decoder_close();if(opus_index_count||decoder_seek(100)||decoder_read(out.pcm,1))return 1;checks++;
 }
 if(!decoder_open(argv[1]))return 1;unsigned cancel=1;ogg_cancel_ptr=&cancel;
 if(decoder_seek(UINT64_MAX)||decode_error||opus_seek_headers||opus_seek_raw)return 1;ogg_cancel_ptr=NULL;
 unsigned n=decoder_read(out.pcm,frames>383?383:(unsigned)frames);if(decode_error||!equal(out.pcm,continuous,n*2,&maximum))return 1;decoder_close();
 ogg_cancel_ptr=&cancel;if(decoder_open(argv[1])||!decode_error)return 1;decoder_close();ogg_cancel_ptr=NULL;if(opus_index_count)return 1;
 printf("{\"result\":\"passed\",\"seek_checks\":%u,\"advanced\":%u,\"frames\":%llu,\"packets\":%u,\"configuration_mask\":%u,\"framing_code_mask\":%u,\"dtx_packets\":%u,\"index_points\":%u,\"maximum_stride\":%llu,\"maximum_skimmed_headers\":%llu,\"maximum_discarded\":%llu,\"maximum_reference_error\":%.9g,\"continuous_reference_values\":%llu,\"maximum_continuous_decode_error\":%.9g,\"maximum_seek_vs_continuous_error\":%.9g,\"cancelled_seek\":1,\"cancelled_open\":1}\n",checks,advanced,frames,packet_count,configurations,framing_codes,dtx_packets,most_points,most_stride,most_headers,most_discarded,maximum,continuous_values,continuous_max,continuous_seek_max);
 opus_decoder_destroy(state);free(continuous);for(unsigned p=0;p<packet_count;p++)free(packets[p].data);free(packets);return 0;
}
