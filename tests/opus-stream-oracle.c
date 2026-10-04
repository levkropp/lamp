/* Full normal packet API oracle; C reference remains test-only. */
#define OPUS_MODE_ORACLE_EMBEDDED
#define OPUS_MODE_CELT_OBSERVER
#include "opus-mode-oracle.c"
typedef struct {ModeState *state;const unsigned char *data;float *pcm;void *work;unsigned len,count,fec,state_cap,work_cap,pcm_cap;} Packet;
typedef char packet_size[(sizeof(Packet)==56)?1:-1];
int op_opus_decode_packet(Packet *);
#ifndef OPUS_STREAM_OGG_EMBEDDED
uint64_t ogg_total_granule,ogg_granule,ogg_packet_page,total_frames;
unsigned ogg_packet_page_end;
unsigned sample_rate,source_channels,source_bits,decode_error;
int ogg_open(void *a,void *b){(void)a;(void)b;return 0;}
void *ogg_next(void){return 0;}
#endif
static unsigned sp_packets,sp_lost,sp_fec,sp_codes[4],sp_guards,sp_late,sp_malformed,sp_dtx_calls;
static uint32_t sp_configs;
static unsigned long long sp_samples;
static int sp_decode(const unsigned char *data,unsigned len,unsigned count,unsigned fec,int malformed){
 static struct {uint64_t before;unsigned char bytes[118944];uint64_t after;} scratch;
 static struct {uint64_t before;float pcm[11520];uint64_t after;} output;
 static unsigned char second_work[118944],saved_payload[65536];static float expected[11520],second_pcm[11520];static ModeState duplicate;
 if(len>sizeof(saved_payload))return 0;if(data&&len)memcpy(saved_payload,data,len);
 memset(&scratch,0xa5,sizeof(scratch));scratch.before=before_guard;scratch.after=after_guard;memset(&output,0xa5,sizeof(output));output.before=before_guard;output.after=after_guard;
 memset(expected,0xa5,sizeof(expected));memset(second_pcm,0xa5,sizeof(second_pcm));memset(second_work,0x71,sizeof(second_work));duplicate=ms;ModeState prior=ms;
 Packet r={&ms,data,output.pcm,scratch.bytes,len,count,fec,26880,118944,11520},saved=r;
 Packet s=r;s.state=&duplicate;s.pcm=second_pcm;s.work=second_work;
 int b=op_opus_decode_packet(&r),c=op_opus_decode_packet(&s);
 mode_reference_celt_errors=0;
 int a=opus_decode_native(mr,data,len,expected,count?count:mr->Fs*120/1000,fec,0,NULL);
 if(malformed&&(a<0||b<=0)){
  CELTDecoder *celt=(CELTDecoder *)((unsigned char *)mr+mr->celt_dec_offset);
  if(b==0){
   if(a>=0||memcmp(&ms,&prior,sizeof(ms))||memcmp(output.pcm,second_pcm,sizeof(second_pcm))){printf("Packet framing rejection%d/%d\n",a,b);return 0;}
   for(unsigned i=0;i<sizeof(scratch.bytes);i++)if(scratch.bytes[i]!=0xa5)return 0;
   for(unsigned i=0;i<sizeof(output.pcm);i++)if(((unsigned char *)output.pcm)[i]!=0xa5)return 0;
  }else if(b!=-1||ms.error!=1||(a>=0&&!mode_reference_celt_errors)){printf("Packet late rejection%d/%d referr%d intermediate%u len%u toc%02x count%u fec%u silkerr%d celterr%d mode%u prev%u frame%u\n",a,b,celt->error,mode_reference_celt_errors,len,data?data[0]:0,count,fec,ms.silk.error,ms.celt.error,ms.mode,ms.prev,ms.frame);return 0;}
  if(c!=b||memcmp(&ms,&duplicate,sizeof(ms))||memcmp(&r,&saved,sizeof(r))||scratch.before!=before_guard||scratch.after!=after_guard||output.before!=before_guard||output.after!=after_guard||(data&&len&&memcmp(data,saved_payload,len)))return 0;
  sp_malformed++;return 1;
 }
 if(a!=b||b<=0||b!=c||memcmp(&ms,&duplicate,sizeof(ms))||memcmp(output.pcm,second_pcm,sizeof(second_pcm))||memcmp(&r,&saved,sizeof(r))||scratch.before!=before_guard||scratch.after!=after_guard||output.before!=before_guard||output.after!=after_guard||mode_state_guard.before!=before_guard||mode_state_guard.after!=after_guard||(data&&len&&memcmp(data,saved_payload,len))){printf("Packet result%d/%d/%d len%u count%u fec%u packet%u\n",a,b,c,len,count,fec,sp_packets);return 0;}
 if(!mode_float("packet PCM",expected,output.pcm,a*mr->channels)||memcmp(expected+a*mr->channels,output.pcm+a*mr->channels,(11520-a*mr->channels)*4)||!mode_history())return 0;
 if(ms.mode!=mode_number(mr->mode)||ms.prev!=mode_number(mr->prev_mode)||ms.frame!=mr->frame_size||ms.stream!=mr->stream_channels||ms.red!=mr->prev_redundancy||ms.range!=mr->rangeFinal||memcmp(&ms.ctrl,&mr->DecControl,sizeof(ms.ctrl))){puts("Packet control/history mismatch");return 0;}
 if(!data||!len)sp_lost++;else {sp_codes[data[0]&3]++;sp_configs|=1u<<(data[0]>>3);}if(fec)sp_fec++;sp_samples+=a*mr->channels;sp_packets++;return 1;
}
static unsigned sp_build(unsigned char *out,unsigned toc,const unsigned char *payload,unsigned n,unsigned code,unsigned frames,unsigned vbr,unsigned padding){
 unsigned at=0;out[at++]=(unsigned char)((toc&~3)|code);
 if(code==0)frames=1;if(code==1||code==2)frames=2;
 if(code==2)at+=encode_size(n,out+at);
 if(code==3){
  out[at++]=(unsigned char)(frames|(vbr?128:0)|(padding?64:0));
  if(padding){unsigned remain=padding;while(remain>=255){out[at++]=255;remain-=254;}out[at++]=(unsigned char)remain;}
  if(vbr)for(unsigned i=1;i<frames;i++)at+=encode_size(n,out+at);
 }
 for(unsigned i=0;i<frames;i++){memcpy(out+at,payload,n);at+=n;}memset(out+at,0,padding);return at+padding;
}
static int sp_encoded(void){
 const int rates[]={8000,12000,16000,24000,48000},celt_bands[]={OPUS_BANDWIDTH_NARROWBAND,OPUS_BANDWIDTH_WIDEBAND,OPUS_BANDWIDTH_SUPERWIDEBAND,OPUS_BANDWIDTH_FULLBAND};
 unsigned char raw[1276],packet[65536];float input[5760];
 for(unsigned config=0;config<32;config++)for(int channels=1;channels<=2;channels++){
  OpusEncoder *enc=opus_encoder_create(48000,channels,OPUS_APPLICATION_AUDIO,NULL);if(!enc)return 0;
  unsigned mode=config<12?MODE_SILK_ONLY:config<16?MODE_HYBRID:MODE_CELT_ONLY;
  unsigned bandwidth=config<12?OPUS_BANDWIDTH_NARROWBAND+config/4:config<16?OPUS_BANDWIDTH_SUPERWIDEBAND+(config-12)/2:celt_bands[(config-16)/4];
  unsigned char wanted=(unsigned char)(config<<3);int N=opus_packet_get_samples_per_frame(&wanted,48000);
  opus_encoder_ctl(enc,OPUS_SET_FORCE_MODE(mode));opus_encoder_ctl(enc,OPUS_SET_BANDWIDTH(bandwidth));opus_encoder_ctl(enc,OPUS_SET_FORCE_CHANNELS(channels));opus_encoder_ctl(enc,OPUS_SET_BITRATE(mode==MODE_CELT_ONLY?128000:48000));opus_encoder_ctl(enc,OPUS_SET_VBR(1));opus_encoder_ctl(enc,OPUS_SET_INBAND_FEC(1));opus_encoder_ctl(enc,OPUS_SET_PACKET_LOSS_PERC(20));
  for(int i=0;i<N;i++)for(int c=0;c<channels;c++)input[i*channels+c]=(float)(.2*sin(i*2*3.141592653589793*(110+70*c)/48000)+.07*sin(i*.37));
  int bytes=opus_encode_float(enc,input,N,raw,sizeof(raw));const unsigned char *parts[48];short sizes[48];unsigned char toc;int offset;
  int frame_count=bytes>0?opus_packet_parse(raw,bytes,&toc,parts,sizes,&offset):-1;opus_encoder_destroy(enc);if(frame_count<1)return 0;
  int source_n=opus_packet_get_samples_per_frame(&toc,48000),max_frames=5760/source_n;
  for(int rate=0;rate<5;rate++)for(int output_ch=1;output_ch<=2;output_ch++){
   if(!mode_reset(output_ch,rates[rate]))return 0;
   for(unsigned code=0;code<4;code++)for(unsigned variation=0;variation<4;variation++){
    unsigned frames=variation%2?max_frames:3;if(frames>(unsigned)max_frames)frames=max_frames;
    unsigned padding=code==3?(variation==0?0:variation==1?1:variation==2?255:768):0;
    unsigned len=sp_build(packet,toc,parts[0],sizes[0],code,frames,variation/2,padding);
    if(!sp_decode(packet,len,0,variation==3,0))return 0;
    if(variation==2&&!sp_decode(NULL,0,0,0,0))return 0;
   }
  }
 }return sp_codes[0]&&sp_codes[1]&&sp_codes[2]&&sp_codes[3];
}
static int sp_invalid(void){
 static unsigned char workbuf[118944],prior_work[118944];static float out[11520],prior_pcm[11520];unsigned char payload[]={0xf8,255,255};
 if(!mode_reset(2,48000))return 0;memset(workbuf,0xa5,sizeof(workbuf));memset(out,0xa5,sizeof(out));
 Packet base={&ms,payload,out,workbuf,3,0,0,26880,118944,1920};
 for(unsigned k=0;k<25;k++){
  Packet r=base;ModeState original=ms;switch(k){case 0:r.state=NULL;break;case 1:r.data=NULL;break;case 2:r.pcm=NULL;break;case 3:r.work=NULL;break;case 4:r.len=0x400001;break;case 5:r.count=5761;break;case 6:r.count=959;break;case 7:r.fec=2;break;case 8:r.state_cap=26879;break;case 9:r.work_cap=118943;break;case 10:r.pcm_cap=1919;break;case 11:ms.tag=0;break;case 12:ms.error=1;break;case 13:ms.channels=0;break;case 14:ms.channels=3;break;case 15:ms.fs=0;break;case 16:ms.fs=44100;break;case 17:r.len=0;r.data=NULL;r.pcm_cap=239;break;case 18:r.len=0;r.data=NULL;r.count=119;break;case 19:r.len=0;r.data=NULL;ms.frame=0;break;case 20:r.len=0;r.data=NULL;ms.prev=4;break;case 21:r.len=0;r.data=NULL;r.count=121;ms.frame=960;ms.prev=3;break;case 22:r.len=0;r.data=NULL;r.count=1440;ms.frame=2880;ms.prev=1;r.pcm_cap=2880;break;case 23:r.count=UINT32_MAX;break;case 24:r.fec=UINT32_MAX;break;}
  Packet saved=r;ModeState prior=ms;memcpy(prior_work,workbuf,sizeof(workbuf));memcpy(prior_pcm,out,sizeof(out));
  if(op_opus_decode_packet(&r)||memcmp(&r,&saved,sizeof(r))||memcmp(&ms,&prior,sizeof(ms))||memcmp(out,prior_pcm,sizeof(out))||memcmp(workbuf,prior_work,sizeof(workbuf))){printf("Packet guard%u\n",k);return 0;}ms=original;sp_guards++;
 }
 if(op_opus_decode_packet(NULL))return 0;sp_guards++;
 ms.celt.period=1023;Packet r=base;if(op_opus_decode_packet(&r)!=-1||ms.error!=1)return 0;ModeState failed=ms;memcpy(prior_work,workbuf,sizeof(workbuf));memcpy(prior_pcm,out,sizeof(out));if(op_opus_decode_packet(&r)||memcmp(&ms,&failed,sizeof(ms))||memcmp(out,prior_pcm,sizeof(out))||memcmp(workbuf,prior_work,sizeof(workbuf)))return 0;
 if(!mode_reset(2,48000)||!sp_decode(payload,3,0,0,0))return 0;sp_late++;return 1;
}
static int sp_dtx(void){
 const int rates[]={8000,12000,16000,24000,48000};unsigned char packet[256],payload=0x7f;
 for(unsigned config=0;config<32;config++)for(unsigned stream=1;stream<=2;stream++)for(unsigned rate=0;rate<5;rate++)for(unsigned channels=1;channels<=2;channels++){
  unsigned toc=(config<<3)|((stream-1)<<2);unsigned char byte=(unsigned char)toc;
  unsigned frame=opus_packet_get_samples_per_frame(&byte,rates[rate]),max_frames=5760/opus_packet_get_samples_per_frame(&byte,48000);
  if(!mode_reset(channels,rates[rate]))return 0;
  for(unsigned code=0;code<4;code++)for(unsigned length=0;length<=1;length++){
   unsigned frames=code==0?1:code==3?max_frames:2;
   unsigned len=sp_build(packet,toc,&payload,length,code,frames,1,code==3?17:0);
   if(!sp_decode(packet,len,frames*frame,length,0))return 0;sp_dtx_calls++;
  }
 }return sp_configs==UINT32_MAX;
}
static int sp_malformed_packets(void){
 unsigned char data[4096];const int rates[]={8000,12000,16000,24000,48000};
 for(unsigned trial=0;trial<2048;trial++){
  unsigned len=1+next()%4096;for(unsigned i=0;i<len;i++)data[i]=(unsigned char)next();
  if(!mode_reset(1+trial%2,rates[trial/2%5])||!sp_decode(data,len,0,trial%7==0,1)){printf("Malformed trial %u rate%d channels%u\n",trial,rates[trial/2%5],1+trial%2);return 0;}
 }return 1;
}
#ifndef OPUS_STREAM_ORACLE_EMBEDDED
int main(void){
 if(!sp_encoded()||!sp_invalid()||!sp_dtx()||!sp_malformed_packets())return 1;
 printf("Opus packets: %u exact packet-to-PCM/history calls (%u/%u/%u/%u framing codes, %u losses, %u FEC), all32 TOC configurations, five API rates and channel layouts, %u zero/one-byte DTX packets, %llu output samples, 2048 malformed cases (%u rejections), %u guards, %u late/sticky/reset checks, max scaled error %.9g\n",sp_packets,sp_codes[0],sp_codes[1],sp_codes[2],sp_codes[3],sp_lost,sp_fec,sp_dtx_calls,sp_samples,sp_malformed,sp_guards,sp_late,mode_max);return 0;
}
#endif
