/* Test-only full RFC6716 SILK API oracle. Runtime remains MASM-only. */
#define SILK_FRAME_ORACLE_EMBEDDED
#include "lamp-test.h"
#include "opus-silk-frame-oracle.c"
#include "API.h"
#include "resampler_private.h"
typedef struct {int vad[2][3],lbrr[2][3],flag[2],frames,channels;} DecoderMeta;
typedef struct {
 FrameState channel[2];stereo_dec_state stereo;uint32_t padding;
 silk_resampler_state_struct rs[2];int api_fs,api_ch,int_ch,prev_mid;
 DecoderMeta meta;int decoded[2],error;uint32_t tag;
} DecoderState;
typedef struct {silk_decoder_state channel[2];stereo_dec_state stereo;int api_ch,int_ch,prev_mid;} NativeDecoder;
typedef struct {DecoderState *state;unsigned cap;} DecoderInit;
typedef struct {DecoderState *state;ec_dec *ec;int16_t *pcm;void *work;silk_DecControlStruct *ctrl;unsigned mode,new_packet,state_cap,ec_cap,pcm_cap,work_cap,ctrl_cap;} Decoder;
LAMP_ABI int op_silk_decoder_init(DecoderInit *);
LAMP_ABI int op_silk_decode(Decoder *);
typedef char decoder_sizes[(sizeof(DecoderState)==8536&&sizeof(DecoderInit)==16&&sizeof(Decoder)==72&&sizeof(silk_DecControlStruct)==24&&offsetof(DecoderState,rs)==7832&&offsetof(DecoderState,meta)==8456&&offsetof(DecoderState,tag)==8532)?1:-1];
typedef struct {uint64_t before;DecoderState value;uint64_t after;} DecoderGuard;
typedef struct {uint64_t before;unsigned char value[8568];uint64_t after;} DecoderWork;
static unsigned kd_initializations,kd_frames,kd_lost,kd_fec,kd_recovered,kd_midonly,kd_continued,kd_api_changes,kd_rate_changes,kd_channel_changes,kd_collapse,kd_adapted,kd_abandoned,kd_guards,kd_late;
static unsigned long long kd_samples,kd_history;
static int kd_rs_equal(const silk_resampler_state_struct *a,const silk_resampler_state_struct *b){
 if(memcmp((const unsigned char *)a+264,(const unsigned char *)b+264,32))return 0;
 if(!a->Coefs||!b->Coefs){if(a->Coefs!=b->Coefs)return 0;}else{
  int count=2+a->FIR_Order/2*a->FIR_Fracs;if(memcmp(a->Coefs,b->Coefs,count*2))return 0;
 }
 if(memcmp(a->sIIR,b->sIIR,sizeof(a->sIIR))||memcmp(a->delayBuf,b->delayBuf,sizeof(a->delayBuf)))return 0;
 return !memcmp(a->sFIR,b->sFIR,sizeof(a->sFIR));
}
static void kd_map(DecoderState *out,const NativeDecoder *ref){
 memset(out,0,sizeof(*out));
 for(int n=0;n<2;n++){
  sf_map(&out->channel[n],&ref->channel[n]);out->rs[n]=ref->channel[n].resampler_state;
  memcpy(out->meta.vad[n],ref->channel[n].VAD_flags,12);memcpy(out->meta.lbrr[n],ref->channel[n].LBRR_flags,12);
  out->meta.flag[n]=ref->channel[n].LBRR_flag;out->decoded[n]=ref->channel[n].nFramesDecoded;
 }
 out->stereo=ref->stereo;out->api_fs=ref->channel[0].fs_API_hz;out->api_ch=ref->api_ch;out->int_ch=ref->int_ch;out->prev_mid=ref->prev_mid;
 out->meta.frames=ref->channel[0].nFramesPerPacket;out->meta.channels=ref->int_ch;out->tag=0x444b4c53;
}
static int kd_equal(const DecoderState *a,const DecoderState *b){
 return !memcmp(a,b,7832)&&kd_rs_equal(&a->rs[0],&b->rs[0])&&kd_rs_equal(&a->rs[1],&b->rs[1])&&!memcmp((const unsigned char *)a+8440,(const unsigned char *)b+8440,96);
}
static int kd_init(DecoderState *state,NativeDecoder *ref){
 int bytes=0;if(silk_Get_Decoder_Size(&bytes)||bytes!=sizeof(*ref)){puts("Native decoder size mismatch");return 0;}
 memset(ref,0,sizeof(*ref));if(silk_InitDecoder(ref))return 0;
 DecoderGuard guard;memset(&guard,0xa5,sizeof(guard));guard.before=0x13579bdf98765432ULL;guard.after=0x2468ace012345678ULL;
 DecoderInit r={&guard.value,8536},saved=r;DecoderState expected;kd_map(&expected,ref);
 if(!op_silk_decoder_init(&r)||!kd_equal(&expected,&guard.value)||memcmp(&r,&saved,sizeof(r))||guard.before!=0x13579bdf98765432ULL||guard.after!=0x2468ace012345678ULL){puts("Decoder initialization mismatch");return 0;}
 *state=guard.value;kd_initializations++;return 1;
}
static int kd_frame(DecoderState *state,NativeDecoder *ref,ec_dec *ec,silk_DecControlStruct control,unsigned mode,unsigned fresh){
 int source_n=control.internalSampleRate/1000*(control.payloadSize_ms<=10?10:20),n=control.API_sampleRate/1000*(control.payloadSize_ms<=10?10:20),elements=n*control.nChannelsAPI;
 int old_fs=ref->channel[0].fs_kHz,old_api=ref->channel[0].fs_API_hz,old_ch=ref->int_ch,old_api_ch=ref->api_ch,old_loss=ref->channel[0].lossCnt;
 int collapse=control.nChannelsInternal==1&&old_ch==2&&old_fs*1000==control.internalSampleRate;
 int adapted=collapse&&old_api!=control.API_sampleRate;
 if(adapted){
  /* The unchanged RFC API resamples the collapsed right channel at its old
     API rate, then copies the new rate's count. Reinitialize only that
     inactive resampler before the reference call to define this edge. */
  if(silk_resampler_init(&ref->channel[1].resampler_state,control.internalSampleRate,control.API_sampleRate,0))return 0;
 }
 DecoderGuard guard,other;memset(&guard,0xa5,sizeof(guard));memset(&other,0xa5,sizeof(other));guard.before=other.before=0x13579bdf98765432ULL;guard.after=other.after=0x2468ace012345678ULL;guard.value=other.value=*state;
 DecoderWork work,second;memset(&work,0xa5,sizeof(work));memset(&second,0x71,sizeof(second));work.before=second.before=guard.before;work.after=second.after=guard.after;
 int16_t x[1922],y[1922],z[1922];for(int i=0;i<1922;i++)x[i]=y[i]=z[i]=-12345;
 ec_dec a=*ec,b=*ec,c=*ec;silk_DecControlStruct ca=control,cb=control,cc=control;
 Decoder r={&guard.value,mode==1?NULL:&b,y+1,work.value,&cb,mode,fresh,8536,mode==1?0:64,elements,8568,24},saved=r;
 Decoder s={&other.value,mode==1?NULL:&c,z+1,second.value,&cc,mode,fresh,8536,mode==1?0:64,elements,8568,24},saved_second=s;
 int count=op_silk_decode(&r),count_second=op_silk_decode(&s);int32_t reference_n=-1;
 if(!count){printf("Decoder late rejection frame%u rate%d/%d ch%d/%d ms%d mode%u fresh%u bits%d state_error%d\n",kd_frames,control.internalSampleRate,control.API_sampleRate,control.nChannelsInternal,control.nChannelsAPI,control.payloadSize_ms,mode,fresh,ec_tell(&b),guard.value.error);return 0;}
 int result=silk_Decode(ref,&ca,mode,fresh,mode==1?NULL:&a,x+1,&reference_n);DecoderState expected;kd_map(&expected,ref);
 if(result||count!=n||count_second!=n||reference_n!=n||memcmp(x,y,sizeof(x))||memcmp(y,z,sizeof(y))||!kd_equal(&expected,&guard.value)||memcmp(&guard.value,&other.value,sizeof(guard.value))||memcmp(&a,&b,sizeof(a))||memcmp(&b,&c,sizeof(b))||memcmp(&ca,&cb,sizeof(ca))||memcmp(&cb,&cc,sizeof(cb))||memcmp(&r,&saved,sizeof(r))||memcmp(&s,&saved_second,sizeof(s))||guard.before!=0x13579bdf98765432ULL||guard.after!=0x2468ace012345678ULL||other.before!=guard.before||other.after!=guard.after||work.before!=guard.before||work.after!=guard.after||second.before!=guard.before||second.after!=guard.after){
  printf("Decoder frame%u rate%d/%d ch%d/%d ms%d mode%u fresh%u count%d/%d/%d result%d adapted%d source%d\n",kd_frames,control.internalSampleRate,control.API_sampleRate,control.nChannelsInternal,control.nChannelsAPI,control.payloadSize_ms,mode,fresh,count,count_second,reference_n,result,adapted,source_n);
  for(int i=0;i<1922;i++)if(x[i]!=y[i]){printf("PCM%d %d/%d\n",i-1,x[i],y[i]);break;}
  for(unsigned i=0;i<sizeof(expected);i++){const unsigned char *u=(const unsigned char *)&expected,*v=(const unsigned char *)&guard.value;if(u[i]!=v[i]&&(i<7832||i>=8440)){printf("State byte%u %u/%u\n",i,u[i],v[i]);break;}}
  for(int j=0;j<2;j++)if(!kd_rs_equal(&expected.rs[j],&guard.value.rs[j])){const unsigned char *u=(const unsigned char *)&expected.rs[j],*v=(const unsigned char *)&guard.value.rs[j];for(unsigned i=0;i<296;i++)if(u[i]!=v[i]){printf("RS%d byte%u %u/%u\n",j,i,u[i],v[i]);break;}}
  if(memcmp(&a,&b,sizeof(a)))printf("Entropy tell%d/%d\n",ec_tell(&a),ec_tell(&b));return 0;
 }
 if(mode==1)kd_lost++;if(mode==2)kd_fec++;if(old_loss&&!ref->channel[0].lossCnt)kd_recovered++;if(ref->prev_mid)kd_midonly++;if(!fresh)kd_continued++;
 if(old_api&&old_api!=control.API_sampleRate)kd_api_changes++;if(old_fs&&old_fs*1000!=control.internalSampleRate)kd_rate_changes++;if(old_ch&&(old_ch!=control.nChannelsInternal||old_api_ch!=control.nChannelsAPI))kd_channel_changes++;if(collapse)kd_collapse++;if(adapted)kd_adapted++;
 *state=guard.value;*ec=b;kd_frames++;kd_samples+=elements;kd_history+=8536;return 1;
}
static void kd_payload(unsigned char *payload,ec_dec *ec,unsigned trial){
 unsigned len=trial%6==0?0:trial%6==1?1:trial%6==2?1275:next()%1276;
 for(unsigned i=0;i<len;i++)payload[i]=(unsigned char)(trial%8==0?0:trial%8==1?255:next());
 memset(ec,0,sizeof(*ec));ec_dec_init(ec,payload,len);if(trial%3==0)ec_dec_bit_logp(ec,3);
}
static int kd_sequences(void){
 const int inputs[]={8000,12000,16000},outputs[]={8000,12000,16000,24000,48000},durations[]={0,10,20,40,60};unsigned char payload[1275];
 for(int in=0;in<3;in++)for(int out=0;out<5;out++)for(int channels=0;channels<4;channels++)for(int duration=0;duration<5;duration++)for(unsigned trial=0;trial<24;trial++){
  DecoderState state;NativeDecoder ref;if(!kd_init(&state,&ref))return 0;
  silk_DecControlStruct ctrl={1+channels/2,1+channels%2,outputs[out],inputs[in],durations[duration],-1};
  int frames=ctrl.payloadSize_ms>20?ctrl.payloadSize_ms/20:1;
  for(unsigned packet=0;packet<6;packet++){
   const unsigned modes[]={0,0,2,1,1,0};ec_dec ec;kd_payload(payload,&ec,trial+packet);unsigned mode=modes[(packet+trial%6)%6];
   for(int f=0;f<frames;f++)if(!kd_frame(&state,&ref,&ec,ctrl,mode,!f))return 0;
  }
 }return 1;
}
static int kd_transitions(void){
 const int inputs[]={8000,12000,16000},outputs[]={8000,12000,16000,24000,48000},durations[]={10,20,40,60};unsigned char payload[1275];
 for(unsigned trial=0;trial<768;trial++){
  DecoderState state;NativeDecoder ref;if(!kd_init(&state,&ref))return 0;
  for(unsigned packet=0;packet<12;packet++){
   if(packet==7&&trial%7==0&&!kd_init(&state,&ref))return 0;
   int int_ch=packet%4<2?2:1,api_ch=(packet+trial)%3?2:1;
   int in=inputs[(trial/5+packet/4)%3],out=outputs[(trial+packet/(trial%2?2:4))%5],ms=durations[(trial+packet)%4],frames=ms>20?ms/20:1;
   silk_DecControlStruct ctrl={api_ch,int_ch,out,in,ms,-1};ec_dec ec;kd_payload(payload,&ec,trial+packet);
   unsigned mode=packet%5==2?1:packet%5==3?2:0;
   int calls=trial%4==1&&(packet==5||packet==9)?1:frames;
   if(calls<frames)kd_abandoned++;
   for(int f=0;f<calls;f++){
    /* API channel count may change safely while continuing a packet. */
    if(f&&trial%3==0)ctrl.nChannelsAPI=3-ctrl.nChannelsAPI;
    if(!kd_frame(&state,&ref,&ec,ctrl,mode,!f))return 0;
   }
  }
 }return 1;
}
static int kd_invalid(void){
 DecoderState state;NativeDecoder ref;if(!kd_init(&state,&ref))return 0;DecoderInit init={&state,8536};
 for(unsigned k=0;k<2;k++){DecoderInit r=init;DecoderState prior=state;if(k)r.cap=8535;else r.state=NULL;DecoderInit saved=r;if(op_silk_decoder_init(&r)||memcmp(&state,&prior,sizeof(state))||memcmp(&r,&saved,sizeof(r)))return 0;kd_guards++;}
 unsigned char payload[1275]={0};ec_dec ec;memset(&ec,0,sizeof(ec));ec_dec_init(&ec,payload,sizeof(payload));silk_DecControlStruct ctrl={2,2,48000,16000,60,-1};
 if(!kd_frame(&state,&ref,&ec,ctrl,0,1))return 0;
 int16_t pcm[1920];unsigned char work[8568];memset(pcm,0xa5,sizeof(pcm));memset(work,0xa5,sizeof(work));Decoder base={&state,&ec,pcm,work,&ctrl,0,0,8536,64,1920,8568,24};
 for(unsigned k=0;k<55;k++){
  DecoderState original=state;ec_dec original_ec=ec;silk_DecControlStruct original_ctrl=ctrl;Decoder r=base;
  switch(k){case 0:r.state=NULL;break;case 1:r.ec=NULL;break;case 2:r.pcm=NULL;break;case 3:r.work=NULL;break;case 4:r.ctrl=NULL;break;case 5:r.mode=3;break;case 6:r.new_packet=2;break;case 7:r.state_cap=8535;break;case 8:r.ec_cap=63;break;case 9:r.pcm_cap=1919;break;case 10:r.work_cap=8567;break;case 11:r.ctrl_cap=23;break;case 12:state.tag=0;break;case 13:state.error=1;break;case 14:ctrl.nChannelsAPI=0;break;case 15:ctrl.nChannelsAPI=3;break;case 16:ctrl.nChannelsInternal=0;break;case 17:ctrl.nChannelsInternal=3;break;case 18:ctrl.API_sampleRate=44100;break;case 19:ctrl.API_sampleRate=0;break;case 20:ctrl.internalSampleRate=24000;break;case 21:ctrl.internalSampleRate=0;break;case 22:ctrl.payloadSize_ms=30;break;case 23:ctrl.payloadSize_ms=-1;break;case 24:state.api_ch=3;break;case 25:state.int_ch=3;break;case 26:state.prev_mid=2;break;case 27:state.meta.frames=4;break;case 28:state.decoded[0]=3;break;case 29:state.decoded[0]=-1;break;case 30:state.decoded[1]=2;break;case 31:state.meta.channels=1;break;case 32:state.api_fs=24000;break;case 33:state.channel[0].fs=12;break;case 34:state.channel[0].subfr=2;break;case 35:ec.buf=NULL;break;case 36:ec.storage=1276;break;case 37:ec.end_offs=1276;break;case 38:ec.offs=1276;break;case 39:ec.rng=0x800000;break;case 40:ec.rng=0x80000001;break;case 41:ec.val=ec.rng;break;case 42:ec.nend_bits=33;break;case 43:ec.nbits_total=32769;break;case 44:r.mode=UINT32_MAX;break;case 45:r.new_packet=UINT32_MAX;break;case 46:state.api_ch=-1;break;case 47:state.int_ch=-1;break;case 48:state.prev_mid=-1;break;case 49:ctrl.nChannelsAPI=-1;break;case 50:ctrl.nChannelsInternal=-1;break;case 51:ctrl.API_sampleRate=-1;break;case 52:ctrl.internalSampleRate=-1;break;case 53:ctrl.payloadSize_ms=120;break;case 54:state.decoded[1]=-1;break;}
  DecoderState prior=state;ec_dec prior_ec=ec;silk_DecControlStruct prior_ctrl=ctrl;Decoder saved=r;int16_t prior_pcm[1920];unsigned char prior_work[8568];memcpy(prior_pcm,pcm,sizeof(pcm));memcpy(prior_work,work,sizeof(work));
  if(op_silk_decode(&r)||memcmp(&state,&prior,sizeof(state))||memcmp(&ec,&prior_ec,sizeof(ec))||memcmp(&ctrl,&prior_ctrl,sizeof(ctrl))||memcmp(&r,&saved,sizeof(r))||memcmp(pcm,prior_pcm,sizeof(pcm))||memcmp(work,prior_work,sizeof(work))){printf("Decoder guard%u\n",k);return 0;}
  state=original;ec=original_ec;ctrl=original_ctrl;kd_guards++;
 }
 if(op_silk_decoder_init(NULL)||op_silk_decode(NULL))return 0;kd_guards+=2;return 1;
}
static int kd_sticky(void){
 unsigned char payload[1275]={0};
 for(unsigned k=0;k<4;k++){
  DecoderState state;NativeDecoder ref;if(!kd_init(&state,&ref))return 0;ec_dec ec;memset(&ec,0,sizeof(ec));ec_dec_init(&ec,payload,sizeof(payload));silk_DecControlStruct ctrl={2,2,48000,16000,60,-1};if(!kd_frame(&state,&ref,&ec,ctrl,0,1))return 0;
  switch(k){case 0:state.channel[0].cng.fs_kHz=16;state.channel[0].cng.CNG_smth_Gain_Q16=-1;break;case 1:state.channel[1].plc.last_frame_lost=2;break;case 2:state.rs[1].resampler_function=4;break;case 3:state.channel[0].param.prev[15]=-1;break;}
  int16_t pcm[1920];unsigned char work[8568];memset(pcm,0xa5,sizeof(pcm));memset(work,0xa5,sizeof(work));Decoder r={&state,&ec,pcm,work,&ctrl,0,0,8536,64,1920,8568,24};
  if(op_silk_decode(&r)||state.error!=1){printf("Decoder sticky trigger%u\n",k);return 0;}
  DecoderState prior=state;ec_dec prior_ec=ec;silk_DecControlStruct prior_ctrl=ctrl;int16_t prior_pcm[1920];unsigned char prior_work[8568];memcpy(prior_pcm,pcm,sizeof(pcm));memcpy(prior_work,work,sizeof(work));
  if(op_silk_decode(&r)||memcmp(&state,&prior,sizeof(state))||memcmp(&ec,&prior_ec,sizeof(ec))||memcmp(&ctrl,&prior_ctrl,sizeof(ctrl))||memcmp(pcm,prior_pcm,sizeof(pcm))||memcmp(work,prior_work,sizeof(work))){printf("Decoder sticky reuse%u\n",k);return 0;}
  if(!kd_init(&state,&ref))return 0;memset(&ec,0,sizeof(ec));ec_dec_init(&ec,payload,sizeof(payload));if(!kd_frame(&state,&ref,&ec,ctrl,0,1))return 0;kd_late++;
 }return 1;
}
#ifndef SILK_DECODER_ORACLE_EMBEDDED
int main(void){
 if(!kd_sequences()||!kd_transitions()||!kd_invalid()||!kd_sticky())return 1;
 printf("SILK decoder API: %u initializations, %u exact packet-to-PCM/history frames across 15 rate pairs and all mono/stereo layouts (%u lost, %u FEC, %u recovered, %u mid-only, %u continued), %u API-rate/%u internal-rate/%u channel transitions, %u stereo collapses (%u defined right-resampler rate adaptations), %u abandoned packets, %llu int16 samples, %llu history bytes, %u late/sticky/reset checks, %u guards; full RFC8251 up-FIR history checked, distinct-scratch ASM history deterministic\n",kd_initializations,kd_frames,kd_lost,kd_fec,kd_recovered,kd_midonly,kd_continued,kd_api_changes,kd_rate_changes,kd_channel_changes,kd_collapse,kd_adapted,kd_abandoned,kd_samples,kd_history,kd_late,kd_guards);return 0;
}
#endif
