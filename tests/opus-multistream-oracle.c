/* Test-only family1 integration oracle. Elementary PCM uses the RFC8251
   decoder; corrected libopus1.5.2 framing supplies packed stream boundaries.
   Channel assignment and RFC7845 downmix formulae are independent of ASM. */
#define OPUS_OGG_ORACLE_EMBEDDED
#include "opus-ogg-oracle.c"
uint64_t opus_seek(uint64_t);
extern uint64_t opus_seek_raw,opus_seek_headers,opus_index_stride;
extern unsigned opus_index_count;
extern unsigned *ogg_cancel_ptr;
static unsigned mu_channels,mu_streams,mu_coupled,mu_skip,mu_count;
static int mu_gain;
static unsigned char mu_map[8],mu_packets[32][65536];
static unsigned mu_lengths[32],mu_samples[32];
static uint64_t mu_raw[32];
static double mu_matrix[8][2];
static float mu_expected[1500000],mu_logical[5760*8];
static unsigned mu_cases,mu_checks,mu_seeks,mu_rejects,mu_cancel,mu_late;
static uint32_t mu_configs,mu_codes;
static uint64_t mu_values;
static float mu_max;
static void mu_weights(void){
 double q=1/sqrt(2.),a=sqrt(3.)/2,s=1;memset(mu_matrix,0,sizeof(mu_matrix));
 if(mu_channels==1){mu_matrix[0][0]=mu_matrix[0][1]=1;return;}
 mu_matrix[0][0]=1;
 if(mu_channels==2){mu_matrix[1][1]=1;return;}
 if(mu_channels==4){mu_matrix[1][1]=1;mu_matrix[2][0]=mu_matrix[3][1]=a;mu_matrix[2][1]=mu_matrix[3][0]=.5;s=1/(1+a+.5);}
 else {
  mu_matrix[1][0]=mu_matrix[1][1]=q;mu_matrix[2][1]=1;
  if(mu_channels==3)s=1/(1+q);
  else {
   mu_matrix[3][0]=mu_matrix[4][1]=a;mu_matrix[3][1]=mu_matrix[4][0]=.5;
   if(mu_channels==5)s=2/(1+q+a+.5);
   if(mu_channels==6){mu_matrix[5][0]=mu_matrix[5][1]=q;s=2/(1+2*q+a+.5);}
   if(mu_channels==7){mu_matrix[5][0]=mu_matrix[5][1]=a*q;mu_matrix[6][0]=mu_matrix[6][1]=q;s=2/(1+2*q+a+.5+a*q);}
   if(mu_channels==8){mu_matrix[5][0]=mu_matrix[6][1]=a;mu_matrix[5][1]=mu_matrix[6][0]=.5;mu_matrix[7][0]=mu_matrix[7][1]=q;s=2/(2+2*q+2*a);}
  }
 }
 for(unsigned c=0;c<mu_channels;c++)for(unsigned o=0;o<2;o++)mu_matrix[c][o]*=s;
}
static OpusDecoder **mu_states(void){
 OpusDecoder **states=calloc(mu_streams,sizeof(*states));if(!states)return NULL;
 for(unsigned s=0;s<mu_streams;s++)if(!(states[s]=opus_decoder_create(48000,s<mu_coupled?2:1,NULL)))return NULL;
 return states;
}
static void mu_free(OpusDecoder **states){if(states){for(unsigned s=0;s<mu_streams;s++)opus_decoder_destroy(states[s]);free(states);}}
static int mu_reference(OpusDecoder **states,const unsigned char *data,unsigned length,float *pcm){
 unsigned remaining=length,frames=0;memset(mu_logical,0,sizeof(mu_logical));float part[11520];
 for(unsigned s=0;s<mu_streams;s++){
  short sizes[48];int consumed;unsigned char toc;
  int count=modern_packet_parse_impl(data,remaining,s+1<mu_streams,&toc,NULL,sizes,NULL,&consumed,NULL,NULL);
  if(count<=0||consumed<=0||(unsigned)consumed>remaining)return 0;
  unsigned n=count*modern_samples_per_frame(data,48000);if(frames&&n!=frames)return 0;frames=n;
  mode_reference_celt_errors=0;
  int got=opus_decode_native(states[s],data,remaining,part,5760,0,s+1<mu_streams,NULL);
  if(got!=(int)n||mode_reference_celt_errors)return 0;
  unsigned channels=s<mu_coupled?2:1,decoded=s<mu_coupled?2*s:s+mu_coupled;
  for(unsigned c=0;c<mu_channels;c++)if(mu_map[c]>=decoded&&mu_map[c]<decoded+channels)
   for(unsigned i=0;i<n;i++)mu_logical[i*mu_channels+c]=part[i*channels+mu_map[c]-decoded];
  data+=consumed;remaining-=consumed;mu_configs|=1u<<(toc>>3);mu_codes|=1u<<(toc&3);
 }
 if(remaining)return 0;
 for(unsigned i=0;i<frames;i++)for(unsigned o=0;o<2;o++){
  double v=0;for(unsigned c=0;c<mu_channels;c++)v+=mu_logical[i*mu_channels+c]*mu_matrix[c][o];pcm[i*2+o]=(float)v;
 }return frames;
}
static unsigned mu_head(unsigned char *head){
 memset(head,0,64);memcpy(head,"OpusHead",8);head[8]=1;head[9]=(unsigned char)mu_channels;
 head[10]=(unsigned char)mu_skip;head[11]=(unsigned char)(mu_skip>>8);og_u32(head+12,44100);
 head[16]=(unsigned char)mu_gain;head[17]=(unsigned char)(mu_gain>>8);head[18]=1;
 head[19]=(unsigned char)mu_streams;head[20]=(unsigned char)mu_coupled;memcpy(head+21,mu_map,mu_channels);return 21+mu_channels;
}
static int mu_file(unsigned trim,uint64_t origin,unsigned variant){
 unsigned char head[64],tags[16]={0};unsigned h=mu_head(head);memcpy(tags,"OpusTags",8);
 og_bytes=og_sequence=og_audio_count=0;
 if(variant==3){head[8]=2;h+=5;}
 if(og_packet_page(head,h,0,2)==UINT32_MAX||og_packet_page(tags,16,0,0)==UINT32_MAX)return 0;
 uint64_t raw=0;
 for(unsigned p=0;p<mu_count;p++){
  mu_raw[p]=raw;raw+=mu_samples[p];unsigned flags=p+1==mu_count?4:0;
  uint64_t gp=origin+raw-(flags?trim:0);unsigned at;
  if(variant==2&&p==0&&mu_lengths[p]>=255){unsigned char lace=255;
   if(og_page(mu_packets[p],255,&lace,1,UINT64_MAX,0)==UINT32_MAX)return 0;
   at=og_packet_page(mu_packets[p]+255,mu_lengths[p]-255,gp,1|flags);
  }else at=og_packet_page(mu_packets[p],mu_lengths[p],gp,flags);
  if(at==UINT32_MAX)return 0;og_audio_pages[og_audio_count++]=at;
 }return raw>=trim+mu_skip;
}
static int mu_equal(const float *actual,const float *expected,unsigned values){
 for(unsigned i=0;i<values;i++){
  float scale=fmaxf(1.f,fabsf(expected[i])),error=fabsf(actual[i]-expected[i])/scale;
  if(!isfinite(actual[i])||!isfinite(expected[i])||error>0.00004f){printf("Family1 PCM case%u value%u %.9g/%.9g error%.9g\n",mu_cases,i,actual[i],expected[i],error);return 0;}
  if(error>mu_max)mu_max=error;mu_values++;
 }return 1;
}
static int mu_verify(unsigned trim,uint64_t origin,unsigned variant){
 mu_weights();if(!mu_file(trim,origin,variant))return 0;memcpy(og_saved,og_file,og_bytes);
 OpusDecoder **states=mu_states();if(!states)return 0;unsigned raw=0;float part[11520];
 for(unsigned p=0;p<mu_count;p++){
  int n=mu_reference(states,mu_packets[p],mu_lengths[p],part);if(n!=(int)mu_samples[p]||raw+(unsigned)n>750000)return 0;
  memcpy(mu_expected+raw*2,part,n*8);raw+=n;
 }mu_free(states);
 unsigned frames=raw-trim-mu_skip;float factor=(float)pow(10.,mu_gain/(20.*256.));
 for(unsigned i=0;i<frames*2;i++)mu_expected[i]=mu_expected[mu_skip*2+i]*factor;
 decode_error=0;total_frames=UINT64_MAX;
 if(!opus_open(og_file,og_file+og_bytes)||decode_error||total_frames!=frames||source_channels!=mu_channels||sample_rate!=48000||source_bits!=32){printf("Family1 open case%u C%u N%u M%u err%u frames%llu/%u\n",mu_cases,mu_channels,mu_streams,mu_coupled,decode_error,total_frames,frames);return 0;}
 static struct {uint64_t before;float pcm[11520];uint64_t after;} out;
 out.before=before_guard;out.after=after_guard;unsigned emitted=0,calls=0;const unsigned caps[]={1,7,119,120,383,960,5760};
 if(opus_read(NULL,1)||opus_read(out.pcm,0))return 0;
 for(;;){
  unsigned cap=caps[calls++%7];memset(out.pcm,0xa5,sizeof(out.pcm));int n=opus_read(out.pcm,cap);
  if(n<0||(unsigned)n>cap||decode_error||emitted+(unsigned)n>frames||out.before!=before_guard||out.after!=after_guard||!mu_equal(out.pcm,mu_expected+emitted*2,n*2)){printf("Family1 read case%u emitted%u got%d err%u\n",mu_cases,emitted,n,decode_error);return 0;}
  for(unsigned i=n*2;i<11520;i++)if(memcmp(out.pcm+i,"\xa5\xa5\xa5\xa5",4))return 0;
  emitted+=n;mu_checks++;if(!n)break;
 }
 if(emitted!=frames||memcmp(og_file,og_saved,og_bytes)||opus_read(out.pcm,1))return 0;opus_close();ogg_close();
 uint64_t requests[]={0,1,119,120,3839,3840,3841,frames/2,frames?frames-1:0,frames,frames+1,UINT64_MAX};
 for(unsigned q=0;q<sizeof(requests)/sizeof(*requests);q++){
  decode_error=0;if(!opus_open(og_file,og_file+og_bytes))return 0;
  uint64_t target=requests[q]>frames?frames:requests[q],position=opus_seek(target),start=opus_seek_raw;
  if(position>target||decode_error||opus_seek_headers>=opus_index_stride||(!start&&position)){puts("Family1 seek position");return 0;}
  unsigned first=0;while(first+1<mu_count&&mu_raw[first+1]<=start)first++;
  if(mu_raw[first]!=start||position!=(start>mu_skip?start-mu_skip:0))return 0;
  unsigned count=frames-target>512?512:(unsigned)(frames-target),copied=0;
  states=mu_states();if(!states)return 0;
  for(unsigned p=first;p<mu_count&&copied<count;p++){
   int n=mu_reference(states,mu_packets[p],mu_lengths[p],part);if(n!=(int)mu_samples[p])return 0;
   for(int i=0;i<n&&copied<count;i++)if(mu_raw[p]+i>=target+mu_skip){mu_expected[copied*2]=part[i*2]*factor;mu_expected[copied*2+1]=part[i*2+1]*factor;copied++;}
  }mu_free(states);if(copied!=count)return 0;
  while(position<target){unsigned discard=target-position>5760?5760:(unsigned)(target-position);int n=opus_read(out.pcm,discard);if(n!=(int)discard||decode_error)return 0;position+=n;}
  int n=opus_read(out.pcm,count?count:1);if(n!=(int)count||decode_error||!mu_equal(out.pcm,mu_expected,count*2))return 0;
  opus_close();ogg_close();if(opus_index_count||opus_read(out.pcm,1))return 0;mu_seeks++;
 }mu_cases++;return 1;
}
static unsigned mu_pack(unsigned char *out,unsigned toc,const unsigned char *payload,unsigned size,unsigned code,unsigned frames,unsigned padding,int self){
 unsigned at=0;out[at++]=(unsigned char)((toc&~3)|code);
 if(code==0)frames=1;if(code==1||code==2)frames=2;
 if(code==2)at+=encode_size(size,out+at);
 if(code==3){out[at++]=(unsigned char)(frames|128|(padding?64:0));if(padding){unsigned left=padding;while(left>=255){out[at++]=255;left-=254;}out[at++]=(unsigned char)left;}for(unsigned f=1;f<frames;f++)at+=encode_size(size,out+at);}
 if(self)at+=encode_size(size,out+at);
 for(unsigned f=0;f<frames;f++){memcpy(out+at,payload,size);at+=size;}memset(out+at,0,padding);return at+padding;
}
static int mu_encoded(void){
 const unsigned nstreams[]={1,1,2,2,3,4,4,5},coupled[]={0,1,1,2,2,2,3,3};
 const unsigned char maps[8][8]={{0},{0,1},{0,2,1},{0,1,2,3},{0,4,1,2,3},{0,4,1,2,3,5},{0,4,1,2,3,5,6},{0,6,1,2,3,4,5,7}};
 const unsigned configs20[]={1,5,9,13,15,19,23,27,31},configs10[]={0,4,8,12,14,18,22,26,30};
 const int bands[]={OPUS_BANDWIDTH_NARROWBAND,OPUS_BANDWIDTH_WIDEBAND,OPUS_BANDWIDTH_SUPERWIDEBAND,OPUS_BANDWIDTH_FULLBAND};
 unsigned char raw[1276];float input[5760];
 for(mu_channels=1;mu_channels<=8;mu_channels++)for(unsigned variant=0;variant<10;variant++){
  mu_streams=nstreams[mu_channels-1];mu_coupled=coupled[mu_channels-1];memcpy(mu_map,maps[mu_channels-1],8);
  if(variant==6)for(unsigned c=0;c<mu_channels;c++)mu_map[c]=(unsigned char)(c+1==mu_channels&&mu_channels>1?255:c%2?0:mu_streams+mu_coupled-1);
  if(variant==7)memset(mu_map,255,mu_channels);
  if(variant==8)for(unsigned c=0;c<mu_channels;c++)mu_map[c]=(unsigned char)(mu_streams+mu_coupled-1-c);
  mu_skip=variant==0?0:variant==3?65535:variant==2?2333:312;mu_gain=variant==0||variant>=6?0:variant==1?-3072:variant==2?1536:variant==3?257:variant==4?32767:-32768;
  mu_count=variant==3?16:24;memset(mu_lengths,0,sizeof(mu_lengths));
  for(unsigned s=0;s<mu_streams;s++){
   unsigned channels=s<mu_coupled?2:1;OpusEncoder *enc=opus_encoder_create(48000,channels,OPUS_APPLICATION_AUDIO,NULL);if(!enc)return 0;
   for(unsigned p=0;p<mu_count;p++){
    unsigned config=variant==9?(s%3==0?16:s%3==1?0:15):variant==3?16:(variant==1||variant==2)?configs10[(p+s*3)%9]:configs20[(p+s*3)%9];
    int mode=config<12?MODE_SILK_ONLY:config<16?MODE_HYBRID:MODE_CELT_ONLY;
    int bandwidth=config<12?OPUS_BANDWIDTH_NARROWBAND+config/4:config<16?OPUS_BANDWIDTH_SUPERWIDEBAND+(config-12)/2:bands[(config-16)/4];
    unsigned char wanted=(unsigned char)(config<<3);unsigned count=opus_packet_get_samples_per_frame(&wanted,48000);
    opus_encoder_ctl(enc,OPUS_SET_FORCE_MODE(mode));opus_encoder_ctl(enc,OPUS_SET_BANDWIDTH(bandwidth));opus_encoder_ctl(enc,OPUS_SET_FORCE_CHANNELS(p%7==0?1:channels));opus_encoder_ctl(enc,OPUS_SET_BITRATE(mode==MODE_CELT_ONLY?128000:48000));
    for(unsigned i=0;i<count;i++)for(unsigned c=0;c<channels;c++)input[i*channels+c]=(float)(.17*sin((i+p*count)*2*3.141592653589793*(113+79*(2*s+c))/48000)+.013*sin(i*.37));
    int bytes=opus_encode_float(enc,input,count,raw,sizeof(raw));const unsigned char *parts[48];short sizes[48];unsigned char toc;
    int f=bytes>0?opus_packet_parse(raw,bytes,&toc,parts,sizes,NULL):-1;if(f!=1)return 0;
    unsigned frames=variant==3?48:(variant==1||variant==2)?2:1,code=variant==3?3:variant==1?1:variant==2?2:p%2?3:0;
    if(variant==9){frames=960/count;code=frames>2?3:frames==2?(p%2?1:2):(p%2?0:3);}
    unsigned padding=code==3?(p%4==0?0:p%4==1?1:p%4==2?255:768):0;
    unsigned offset=mu_lengths[p];unsigned length=mu_pack(mu_packets[p]+offset,toc,parts[0],sizes[0],code,frames,padding,s+1<mu_streams);
    mu_lengths[p]+=length;mu_samples[p]=frames*count;if(mu_lengths[p]>65536)return 0;
   }opus_encoder_destroy(enc);
  }
  if(!mu_verify(variant?17:0,variant==1?1234567:0,variant))return 0;
 }return 1;
}
static int mu_maps(void){
 const unsigned counts[][2]={{1,0},{1,1},{2,1},{255,0},{128,127},{127,127}};
 mu_channels=8;mu_skip=23;mu_gain=0;mu_count=8;
 for(unsigned v=0;v<sizeof(counts)/sizeof(*counts);v++){
  mu_streams=counts[v][0];mu_coupled=counts[v][1];unsigned decoded=mu_streams+mu_coupled;
  for(unsigned c=0;c<8;c++)mu_map[c]=(unsigned char)(c==7?255:c==6?decoded-1:c%decoded);
  for(unsigned p=0;p<mu_count;p++){
   unsigned at=0;for(unsigned s=0;s<mu_streams;s++){unsigned char zero=0;at+=mu_pack(mu_packets[p]+at,0xf8|((p%2&&s<mu_coupled)?4:0),&zero,p%2,0,1,0,s+1<mu_streams);}
   mu_lengths[p]=at;mu_samples[p]=960;
  }
  if(!mu_verify(7,7890123,0))return 0;
 }return 1;
}
static int mu_bad(void){
 unsigned char head[64],tags[16]={0},audio[8]={0xf8,0,0xf8};memcpy(tags,"OpusTags",8);
 mu_channels=3;mu_streams=2;mu_coupled=1;mu_skip=0;mu_gain=0;mu_map[0]=0;mu_map[1]=2;mu_map[2]=1;
 for(unsigned trial=0;trial<15;trial++){
  unsigned h=mu_head(head),length=3;audio[0]=audio[2]=0xf8;audio[1]=0;audio[3]=255;og_bytes=og_sequence=0;
  switch(trial){case 0:head[9]=0;break;case 1:head[9]=9;break;case 2:head[19]=0;break;case 3:head[20]=3;break;case 4:head[19]=200;head[20]=100;break;case 5:head[21]=3;break;case 6:head[18]=2;break;case 7:head[18]=255;break;case 8:h--;break;case 9:h++;break;case 10:head[8]=16;break;case 11:audio[2]=0xf0;break;case 12:length=2;break;case 13:audio[1]=127;break;case 14:audio[0]=0xfb;audio[1]=0;break;}
  if(og_packet_page(head,h,0,2)==UINT32_MAX||og_packet_page(tags,16,0,0)==UINT32_MAX||og_packet_page(audio,length,960,4)==UINT32_MAX)return 0;
  decode_error=0;if(opus_open(og_file,og_file+og_bytes)||!decode_error||total_frames||opus_index_count){printf("Family1 invalid accepted trial%u err%u\n",trial,decode_error);return 0;}
  opus_close();ogg_close();mu_rejects++;
 }
 /* A bad unmapped stream must still be decoded and reject the whole read. */
 mu_channels=1;mu_coupled=0;mu_map[0]=0;mu_weights();unsigned char bad[128];float output[11520];int found=0;
 for(unsigned trial=0;trial<1024&&!found;trial++){
  unsigned length=3+next()%61;bad[0]=0xf8;for(unsigned i=1;i<length;i++)bad[i]=(unsigned char)next();
  if(!mode_reset(1,48000))return 0;mode_reference_celt_errors=0;int n=opus_decode_native(mr,bad,length,output,5760,0,0,NULL);
  if(n>=0&&!mode_reference_celt_errors)continue;
  unsigned char packet[128]={0xf8,0};memcpy(packet+2,bad,length);unsigned h=mu_head(head);og_bytes=og_sequence=0;
  og_packet_page(head,h,0,2);og_packet_page(tags,16,0,0);og_packet_page(packet,length+2,960,4);decode_error=0;
  if(!opus_open(og_file,og_file+og_bytes)||decode_error||opus_read(output,5760)||decode_error!=27){puts("Family1 unmapped late error");return 0;}
  memset(output,0xa5,sizeof(output));if(opus_read(output,1)||memcmp(output,"\xa5\xa5\xa5\xa5",4))return 0;opus_close();ogg_close();mu_late++;found=1;
 }if(!found)return 0;
 /* Restore a valid multi-stream fixture and check cancel/open/read/seek. */
 mu_count=1;mu_samples[0]=960;mu_lengths[0]=3;memcpy(mu_packets[0],audio,3);mu_packets[0][0]=mu_packets[0][2]=0xf8;mu_packets[0][1]=0;
 if(!mu_file(0,0,0))return 0;unsigned cancel=1;ogg_cancel_ptr=&cancel;decode_error=0;
 if(opus_open(og_file,og_file+og_bytes)||!decode_error)return 0;mu_cancel++;
 cancel=0;decode_error=0;if(!opus_open(og_file,og_file+og_bytes))return 0;cancel=1;
 if(opus_seek(500)||decode_error||opus_seek_headers||opus_seek_raw)return 0;mu_cancel++;
 if(opus_read(output,5760)||decode_error!=27)return 0;mu_cancel++;
 ogg_cancel_ptr=NULL;opus_close();ogg_close();return 1;
}
int main(void){
 if(!mu_encoded()||!mu_maps()||!mu_bad())return 1;
 printf("Opus family1: %u generated reference PCM streams, C1..8, N1..255, M0..127, all speaker matrices, repeated/silent/unmapped channels, mixed mode/channel transitions, four framing codes, 48-frame/120ms packets, padding, pre-skip0..65535, signed gain extremes, continued audio and future minor headers; %llu stereo values, %u bounded read/canary checks, %u reset-reference seeks, %u malformed rejections, %u unmapped late/sticky errors, %u cancellation checks, TOC mask%08x framing mask%x, max scaled error%.9g\n",mu_cases,mu_values,mu_checks,mu_seeks,mu_rejects,mu_late,mu_cancel,mu_configs,mu_codes,mu_max);return 0;
}
