/* Full normative mode decoder is included unchanged for private history. */
#define main embedded_celt_oracle_main
#define Frame CeltFrame
#include "opus-decoder-oracle.c"
#undef Frame
#undef main
#undef MAX_PULSES
#define SILK_DECODER_ORACLE_EMBEDDED
#define Frame SilkFrame
#define WorkGuard SilkWorkGuard
#define invalid embedded_silk_invalid
#include "opus-silk-decoder-oracle.c"
#undef invalid
#undef WorkGuard
#undef Frame
#include "opus_decoder.c"
typedef struct {
 uint32_t tag;int channels,fs,stream,mode,end,prev,frame,red;uint32_t range;int error,reserved;
 silk_DecControlStruct ctrl;DecoderState silk;LampState celt;
} ModeState;
typedef struct {ModeState *state;int fs,channels;unsigned cap;} ModeInit;
typedef struct {ModeState *state;const unsigned char *data;float *pcm;void *work;unsigned len,config,stream,count,fec,state_cap,work_cap,pcm_cap;} ModeFrame;
int op_opus_decoder_init(ModeInit *);
int op_opus_decode_frame(ModeFrame *);
typedef char mode_sizes[(sizeof(ModeState)==26880&&sizeof(ModeFrame)==64&&sizeof(ModeInit)==24&&offsetof(ModeState,silk)==72&&offsetof(ModeState,celt)==8608)?1:-1];
static struct {uint64_t before;ModeState value;uint64_t after;} mode_state_guard;
#define ms mode_state_guard.value
static OpusDecoder *mr;
static unsigned mode_frames,mode_silk,mode_hybrid,mode_celt,mode_losses,mode_fec,mode_transitions,mode_redundant,mode_guards,mode_rejections;
static unsigned mode_red_to_silk,mode_red_to_celt,mode_malformed;
static uint32_t mode_configs;
static unsigned long long mode_values;
static float mode_max;
static int mode_number(int value){return value==MODE_SILK_ONLY?1:value==MODE_HYBRID?2:value==MODE_CELT_ONLY?3:0;}
static int mode_band(int bandwidth){return bandwidth==OPUS_BANDWIDTH_NARROWBAND?13:bandwidth<=OPUS_BANDWIDTH_WIDEBAND?17:bandwidth==OPUS_BANDWIDTH_SUPERWIDEBAND?19:21;}
static int mode_reset(int channels,int fs){
 if(mr)free(mr);mr=(OpusDecoder *)calloc(1,opus_decoder_get_size(channels));if(!mr||opus_decoder_init(mr,fs,channels))return 0;
 memset(&ms,0xa5,sizeof(ms));ModeInit r={&ms,fs,channels,26880},saved=r;
 mode_state_guard.before=before_guard;mode_state_guard.after=after_guard;
 if(!op_opus_decoder_init(&r)||memcmp(&r,&saved,sizeof(r))||ms.tag!=0x31444f4d||ms.fs!=fs||ms.channels!=channels||ms.frame!=fs/400||ms.error||mode_state_guard.before!=before_guard||mode_state_guard.after!=after_guard){puts("Mode initialization mismatch");return 0;}return 1;
}
static int mode_float(const char *kind,const float *a,const float *b,unsigned n){
 for(unsigned i=0;i<n;i++){
  float error=fabsf(a[i]-b[i]),scale=fmaxf(1.f,fabsf(a[i]));if(!isfinite(a[i])||!isfinite(b[i])||error>scale*0.00004f){printf("Mode %s[%u] %.9g/%.9g frame%u\n",kind,i,a[i],b[i],mode_frames);return 0;}if(error/scale>mode_max)mode_max=error/scale;mode_values++;
 }return 1;
}
static int mode_history(void){
 NativeDecoder *silk=(NativeDecoder *)((unsigned char *)mr+mr->silk_dec_offset);CELTDecoder *celt=(CELTDecoder *)((unsigned char *)mr+mr->celt_dec_offset);DecoderState expected;kd_map(&expected,silk);
 /* A never-used/reset private SILK state's metadata channel count is zero
    until a packet is configured; the reference stores it in its super state. */
 if(!silk->channel[0].nFramesPerPacket)expected.meta.channels=0;
 if(!kd_equal(&expected,&ms.silk)){const unsigned char *a=(const unsigned char *)&expected,*b=(const unsigned char *)&ms.silk;for(unsigned i=0;i<sizeof(expected);i++)if((i<7832||i>=8440)&&a[i]!=b[i]){printf("Mode SILK state byte%u %u/%u frame%u\n",i,a[i],b[i],mode_frames);break;}return 0;}
 LampState *s=&ms.celt;int CC=mr->channels;
 if(s->rng!=celt->rng||s->period!=celt->postfilter_period||s->period_old!=celt->postfilter_period_old||s->gain!=celt->postfilter_gain||s->gain_old!=celt->postfilter_gain_old||s->tap!=celt->postfilter_tapset||s->tap_old!=celt->postfilter_tapset_old||s->loss!=celt->loss_count||s->last_pitch!=celt->last_pitch_index){printf("Mode CELT scalars rng%u/%u loss%d/%d frame%u\n",s->rng,celt->rng,s->loss,celt->loss_count,mode_frames);return 0;}
 float *lpc=celt->_decode_mem+CC*2168,*old=lpc+CC*24;
 return mode_float("CELT history",celt->_decode_mem,s->decode[0],CC*2168)&&mode_float("CELT LPC",lpc,s->lpc[0],CC*24)&&mode_float("CELT energy",old,s->old,168)&&mode_float("deemphasis",celt->preemph_memD,s->deemph,2);
}
static int mode_decode(const unsigned char *payload,unsigned len,unsigned config,unsigned stream,unsigned count,unsigned fec,int may_reject){
 static struct {uint64_t before;unsigned char value[118944];uint64_t after;} mw;
 static struct {uint64_t before;float value[11520];uint64_t after;} mp;
 static float x[11520];int old_mode=mr->prev_mode;
 unsigned char saved_payload[1275];if(payload&&len)memcpy(saved_payload,payload,len);
 static ModeState duplicate;static unsigned char other_work[118944];static float other_pcm[11520];duplicate=ms;memset(other_work,0x71,sizeof(other_work));memset(other_pcm,0xa5,sizeof(other_pcm));
 memset(&mw,0xa5,sizeof(mw));mw.before=before_guard;mw.after=after_guard;memset(&mp,0xa5,sizeof(mp));mp.before=before_guard;mp.after=after_guard;memset(x,0xa5,sizeof(x));
 unsigned char toc=(unsigned char)((config<<3)|((stream-1)<<2));
 if(payload){mr->mode=opus_packet_get_mode(&toc);mr->bandwidth=opus_packet_get_bandwidth(&toc);mr->frame_size=opus_packet_get_samples_per_frame(&toc,mr->Fs);mr->stream_channels=stream;}
 int limit=count?count:mr->frame_size;
 ModeFrame r={&ms,payload,mp.value,mw.value,len,config,stream,count,fec,26880,118944,11520},saved=r;
 ModeFrame second=r;second.state=&duplicate;second.pcm=other_pcm;second.work=other_work;
 int second_n=op_opus_decode_frame(&second);
 int b=op_opus_decode_frame(&r),a=opus_decode_frame(mr,payload,len,x,limit,fec);
 if(may_reject&&(b<0||a<0)){
  CELTDecoder *celt=(CELTDecoder *)((unsigned char *)mr+mr->celt_dec_offset);
  if(b>=0||ms.error!=1||(a>=0&&!celt->error)||b!=second_n||memcmp(&ms,&duplicate,sizeof(ms))||memcmp(&r,&saved,sizeof(r))||mw.before!=before_guard||mw.after!=after_guard||mp.before!=before_guard||mp.after!=after_guard||mode_state_guard.before!=before_guard||mode_state_guard.after!=after_guard||memcmp(payload,saved_payload,len)){printf("Mode rejected frame result%d/%d cfg%u len%u referr%d silkerr%d celterr%d\n",a,b,config,len,celt->error,ms.silk.error,ms.celt.error);return 0;}
  static ModeState failed;static unsigned char failed_work[118944];static float failed_pcm[11520];failed=ms;memcpy(failed_work,mw.value,sizeof(failed_work));memcpy(failed_pcm,mp.value,sizeof(failed_pcm));
  if(op_opus_decode_frame(&r)||memcmp(&ms,&failed,sizeof(ms))||memcmp(failed_work,mw.value,sizeof(failed_work))||memcmp(failed_pcm,mp.value,sizeof(failed_pcm))){puts("Malformed mode failure not sticky");return 0;}
  mode_rejections++;return 1;
 }
 if(payload&&len&&memcmp(payload,saved_payload,len)){puts("Mode payload was changed");return 0;}
 if(a!=b||a<=0||b!=second_n||memcmp(&ms,&duplicate,sizeof(ms))||memcmp(mp.value,other_pcm,sizeof(other_pcm))||memcmp(&r,&saved,sizeof(r))||mw.before!=before_guard||mw.after!=after_guard||mp.before!=before_guard||mp.after!=after_guard||mode_state_guard.before!=before_guard||mode_state_guard.after!=after_guard){printf("Mode result%d/%d/%d len%u cfg%u stream%u count%u fec%u prev%d frame%u error%d\n",a,b,second_n,len,config,stream,count,fec,old_mode,mode_frames,ms.error);return 0;}
 if(!mode_float("PCM",x,mp.value,a*mr->channels)||memcmp(x+a*mr->channels,mp.value+a*mr->channels,(11520-a*mr->channels)*4))return 0;
 if(ms.mode!=mode_number(mr->mode)||ms.prev!=mode_number(mr->prev_mode)||ms.frame!=mr->frame_size||ms.stream!=mr->stream_channels||ms.red!=mr->prev_redundancy||ms.range!=mr->rangeFinal||memcmp(&ms.ctrl,&mr->DecControl,sizeof(ms.ctrl))){printf("Mode header mode%d/%d prev%d/%d frame%d/%d range%u/%u red%d/%d ctrl%d frame%u\n",ms.mode,mode_number(mr->mode),ms.prev,mode_number(mr->prev_mode),ms.frame,mr->frame_size,ms.range,mr->rangeFinal,ms.red,mr->prev_redundancy,memcmp(&ms.ctrl,&mr->DecControl,sizeof(ms.ctrl)),mode_frames);return 0;}
 if(!mode_history())return 0;
 if(!payload||len<=1)mode_losses++;if(fec)mode_fec++;if(old_mode&&old_mode!=mr->prev_mode)mode_transitions++;if(mr->prev_redundancy)mode_redundant++;
 if(payload&&len>1)mode_configs|=1u<<config;
 if(payload&&len>1&&!fec&&*(uint32_t *)(mw.value+8)<len){if(ms.red)mode_red_to_celt++;else mode_red_to_silk++;}
 if(ms.prev==1)mode_silk++;if(ms.prev==2)mode_hybrid++;if(ms.prev==3)mode_celt++;mode_frames++;return 1;
}
static int mode_initial_loss(void){
 const int rates[]={8000,12000,16000,24000,48000};
 for(int rate=0;rate<5;rate++)for(int channels=1;channels<=2;channels++){
  if(!mode_reset(channels,rates[rate]))return 0;
  for(unsigned n=1;n<=48;n*=2)if(!mode_decode(NULL,0,0,channels,rates[rate]/400*n,0,0))return 0;
 }return 1;
}
static int mode_encoded(void){
 const int rates[]={8000,12000,16000,24000,48000};unsigned char packet[1276];float input[5760];
 for(int channels=1;channels<=2;channels++)for(int variant=0;variant<12;variant++){
  OpusEncoder *enc=opus_encoder_create(48000,channels,OPUS_APPLICATION_AUDIO,NULL);if(!enc)return 0;
  opus_encoder_ctl(enc,OPUS_SET_BITRATE(12000+variant*6000));opus_encoder_ctl(enc,OPUS_SET_VBR(0));opus_encoder_ctl(enc,OPUS_SET_INBAND_FEC(1));opus_encoder_ctl(enc,OPUS_SET_PACKET_LOSS_PERC(20));
  unsigned char payloads[48][1276];unsigned lengths[48],configs[48],streams[48];
  for(unsigned p=0;p<48;p++){
   int mode=p/8%3;opus_encoder_ctl(enc,OPUS_SET_FORCE_MODE(mode==0?MODE_SILK_ONLY:mode==1?MODE_HYBRID:MODE_CELT_ONLY));
   const int celt_bands[]={OPUS_BANDWIDTH_NARROWBAND,OPUS_BANDWIDTH_WIDEBAND,OPUS_BANDWIDTH_SUPERWIDEBAND,OPUS_BANDWIDTH_FULLBAND};
   opus_encoder_ctl(enc,OPUS_SET_BANDWIDTH(mode==0?OPUS_BANDWIDTH_NARROWBAND+variant%3:mode==1?OPUS_BANDWIDTH_SUPERWIDEBAND+variant%2:celt_bands[variant%4]));
   const int silk_sizes[]={480,960,1920,2880},celt_sizes[]={120,240,480,960};
   int N=mode==0?silk_sizes[(p+variant)%4]:mode==1?480*((p+variant)%2+1):celt_sizes[(p+variant)%4];
   for(int i=0;i<N;i++)for(int c=0;c<channels;c++)input[i*channels+c]=(float)(.2*sin((p*N+i)*2*3.141592653589793*(110+70*c)/48000)+.05*sin(i*.37));
   int len=opus_encode_float(enc,input,N,packet,sizeof(packet));const unsigned char *ptrs[48];short sizes[48];unsigned char toc;int offset;
   int count=len>0?opus_packet_parse(packet,len,&toc,ptrs,sizes,&offset):-1;
   if(count<=0){printf("Mode encoder framing len%d toc%u count%d\n",len,packet[0],count);return 0;}
   lengths[p]=len;configs[p]=toc>>3;streams[p]=1+((toc>>2)&1);memcpy(payloads[p],packet,len);
  }
  opus_encoder_destroy(enc);
  for(int rate=0;rate<5;rate++)for(int output_ch=1;output_ch<=2;output_ch++){
   if(!mode_reset(output_ch,rates[rate]))return 0;
   for(unsigned p=0;p<48;p++){
    const unsigned char *ptrs[48];short sizes[48];unsigned char toc;int offset;
    int count=opus_packet_parse(payloads[p],lengths[p],&toc,ptrs,sizes,&offset);
    for(int f=0;f<count;f++)if(!mode_decode(ptrs[f],sizes[f],configs[p],streams[p],0,p%7==4,0))return 0;
    if(p%9==8)for(unsigned loss=0;loss<3;loss++)if(!mode_decode(NULL,0,configs[p],streams[p],rates[rate]/50,0,0))return 0;
   }
  }
 }return mode_silk&&mode_hybrid&&mode_celt&&mode_transitions;
}
static int mode_malformed_packets(void){
 const int rates[]={8000,12000,16000,24000,48000};unsigned char payload[1275],silence[]={255,255};
 for(unsigned trial=0;trial<2048;trial++){
  unsigned channels=1+trial%2,rate=rates[trial/2%5],config=trial/10%32,len=trial%4==0?2:trial%4==1?1275:2+next()%1274;
  for(unsigned i=0;i<len;i++)payload[i]=(unsigned char)(trial%11==0?0:trial%11==1?255:next());
  if(!mode_reset(channels,rate)||!mode_decode(payload,len,config,1+trial/320%2,0,trial%7==0,1))return 0;
  if(!mode_reset(channels,rate)||!mode_decode(silence,2,31,channels,0,0,0))return 0;mode_malformed++;
 }return 1;
}
static int mode_invalid(void){
 static float pcm_out[11520],prior_pcm[11520];static unsigned char scratch[118944],prior_work[118944];
 unsigned char payload[]={255,255};if(!mode_reset(2,48000))return 0;
 ModeInit init={&ms,48000,2,26880};
 for(unsigned k=0;k<8;k++){
  ModeInit r=init;switch(k){case 0:r.state=NULL;break;case 1:r.cap=26879;break;case 2:r.fs=0;break;case 3:r.fs=44100;break;case 4:r.channels=0;break;case 5:r.channels=3;break;case 6:r.fs=-1;break;case 7:r.channels=-1;break;}
  ModeInit saved=r;ModeState prior=ms;if(op_opus_decoder_init(&r)||memcmp(&ms,&prior,sizeof(ms))||memcmp(&r,&saved,sizeof(r))){printf("Mode init guard%u\n",k);return 0;}mode_guards++;
 }
 memset(pcm_out,0xa5,sizeof(pcm_out));memset(scratch,0xa5,sizeof(scratch));
 ModeFrame base={&ms,payload,pcm_out,scratch,2,31,2,0,0,26880,118944,1920};
 for(unsigned k=0;k<39;k++){
  ModeFrame r=base;ModeState original=ms;
  switch(k){case 0:r.state=NULL;break;case 1:r.data=NULL;break;case 2:r.pcm=NULL;break;case 3:r.work=NULL;break;case 4:r.len=1276;break;case 5:r.config=32;break;case 6:r.stream=0;break;case 7:r.stream=3;break;case 8:r.count=119;break;case 9:r.count=959;break;case 10:r.count=5761;break;case 11:r.fec=2;break;case 12:r.state_cap=26879;break;case 13:r.work_cap=118943;break;case 14:r.pcm_cap=1919;break;case 15:ms.tag=0;break;case 16:ms.error=1;break;case 17:ms.channels=0;break;case 18:ms.channels=3;break;case 19:ms.fs=0;break;case 20:ms.fs=44100;break;case 21:ms.prev=4;break;case 22:ms.red=2;break;case 23:r.config=UINT32_MAX;break;case 24:r.stream=UINT32_MAX;break;case 25:r.count=UINT32_MAX;break;case 26:r.fec=UINT32_MAX;break;case 27:ms.channels=-1;break;case 28:ms.prev=-1;break;case 29:ms.red=-1;break;}
  switch(k){case 30:ms.frame=0;break;case 31:ms.frame=121;break;case 32:ms.mode=4;break;case 33:ms.stream=0;break;case 34:ms.ctrl.API_sampleRate=8000;break;case 35:ms.ctrl.nChannelsAPI=1;break;case 36:ms.celt.channels=1;break;case 37:ms.celt.downsample=2;break;case 38:r.data=NULL;r.len=0;r.count=121;ms.frame=960;ms.prev=3;break;}
  ModeState prior=ms;ModeFrame saved=r;memcpy(prior_pcm,pcm_out,sizeof(pcm_out));memcpy(prior_work,scratch,sizeof(scratch));
  if(op_opus_decode_frame(&r)||memcmp(&ms,&prior,sizeof(ms))||memcmp(&r,&saved,sizeof(r))||memcmp(pcm_out,prior_pcm,sizeof(pcm_out))||memcmp(scratch,prior_work,sizeof(scratch))){printf("Mode guard%u\n",k);return 0;}
  ms=original;mode_guards++;
 }
 if(op_opus_decoder_init(NULL)||op_opus_decode_frame(NULL))return 0;mode_guards+=2;
 ms.celt.period=1023;ModeFrame r=base;
 if(op_opus_decode_frame(&r)!=-1||ms.error!=1){puts("Mode late failure trigger");return 0;}
 ModeState prior=ms;memcpy(prior_pcm,pcm_out,sizeof(pcm_out));memcpy(prior_work,scratch,sizeof(scratch));
 if(op_opus_decode_frame(&r)||memcmp(&ms,&prior,sizeof(ms))||memcmp(pcm_out,prior_pcm,sizeof(pcm_out))||memcmp(scratch,prior_work,sizeof(scratch))){puts("Mode failure not sticky");return 0;}
 if(!mode_reset(2,48000)||!mode_decode(payload,2,31,2,0,0,0))return 0;mode_rejections++;return 1;
}
int main(void){
 if(!mode_initial_loss()||!mode_encoded()||!mode_malformed_packets()||!mode_invalid())return 1;
 if(mode_configs!=UINT32_MAX||!mode_red_to_silk||!mode_red_to_celt){printf("Insufficient mode coverage toc%08x redundancy%u/%u\n",mode_configs,mode_red_to_silk,mode_red_to_celt);return 1;}
 printf("Opus modes: %u frames (%u SILK, %u hybrid, %u CELT, %u losses, %u FEC, %u transitions), %u CELT-to-SILK/%u SILK-to-CELT redundant frames, all32 TOC configs, %u malformed cases, %llu float PCM/history values, %u guards, %u strict rejection/sticky/reset cases, max scaled error %.9g\n",mode_frames,mode_silk,mode_hybrid,mode_celt,mode_losses,mode_fec,mode_transitions,mode_red_to_silk,mode_red_to_celt,mode_malformed,mode_values,mode_guards,mode_rejections,mode_max);return 0;
}
