/* Test-only unchanged init/set_fs/decode_frame reference, all frame history. */
#define main silk_synthesis_oracle_main
#include "lamp-test.h"
#include "opus-silk-synthesis-oracle.c"
#undef main
#include <stddef.h>
typedef struct {Core core;ParamState param;Previous previous;SideInfoIndices ind;silk_PLC_struct plc;silk_CNG_struct cng;int fs,subfr,error;uint32_t tag;} FrameState;
typedef struct {FrameState *state;int fs,subfr;unsigned cap;} FrameInit;
typedef struct {FrameState *state;ec_dec *ec;int16_t *pcm;void *work;unsigned mode,vad,lbrr,cond,state_cap,ec_cap,pcm_cap,work_cap;} Frame;
LAMP_ABI int op_silk_frame_init(FrameInit *);
LAMP_ABI int op_silk_frame_config(FrameInit *);
LAMP_ABI int op_silk_decode_frame(Frame *);
typedef char frame_sizes[(sizeof(FrameState)==3908&&sizeof(FrameInit)==24&&sizeof(Frame)==64&&offsetof(FrameState,plc)==2412&&offsetof(FrameState,cng)==2504&&offsetof(FrameState,tag)==3904)?1:-1];
typedef struct {uint64_t before;FrameState value;uint64_t after;} FrameGuard;
typedef struct {uint64_t before;unsigned char value[5360];uint64_t after;} FrameWork;
static unsigned sf_initializations,sf_configurations,sf_frames,sf_losses,sf_fec,sf_voiced,sf_recovered,sf_rate_changes,sf_continued,sf_late,sf_guards;
static unsigned long long sf_samples,sf_state_bytes;
static void sf_map(FrameState *out,const silk_decoder_state *ref){
 memset(out,0,sizeof(*out));out->core.gain=ref->prev_gain_Q16;memcpy(out->core.exc,ref->exc_Q14,sizeof(out->core.exc));memcpy(out->core.lpc,ref->sLPC_Q14_buf,sizeof(out->core.lpc));memcpy(out->core.out,ref->outBuf,sizeof(out->core.out));
 out->core.lag=ref->lagPrev;out->core.signal=ref->prevSignalType;out->core.loss=ref->lossCnt;out->param.gain=ref->LastGainIndex;memcpy(out->param.prev,ref->prevNLSF_Q15,sizeof(out->param.prev));out->param.first=ref->first_frame_after_reset;out->param.loss=ref->lossCnt;
 out->previous.lag=ref->ec_prevLagIndex;out->previous.signal=ref->ec_prevSignalType;out->ind=ref->indices;out->plc=ref->sPLC;out->cng=ref->sCNG;out->fs=ref->fs_kHz;out->subfr=ref->nb_subfr;out->tag=0x464b4c53;
}
static int sf_init(FrameState *state,silk_decoder_state *ref,int fs,int subfr){
 memset(state,0xa5,sizeof(*state));silk_init_decoder(ref);ref->nb_subfr=subfr;if(silk_decoder_set_fs(ref,fs,48000))return 0;FrameState expected;sf_map(&expected,ref);FrameInit r={state,fs,subfr,3908},saved=r;
 if(!op_silk_frame_init(&r)||memcmp(state,&expected,sizeof(*state))||memcmp(&r,&saved,sizeof(r))){printf("Frame init fs%d subfr%d\n",fs,subfr);return 0;}sf_initializations++;return 1;
}
static int sf_config(FrameState *state,silk_decoder_state *ref,int fs,int subfr){
 int oldfs=state->fs;ref->nb_subfr=subfr;if(silk_decoder_set_fs(ref,fs,48000))return 0;FrameState expected;sf_map(&expected,ref);FrameInit r={state,fs,subfr,3908},saved=r;
 if(!op_silk_frame_config(&r)||memcmp(state,&expected,sizeof(*state))||memcmp(&r,&saved,sizeof(r))){printf("Frame config fs%d subfr%d oldfs%d\n",fs,subfr,oldfs);return 0;}sf_configurations++;if(oldfs!=fs)sf_rate_changes++;return 1;
}
static int sf_valid(const int16_t *x,const silk_NLSF_CB_struct *cb){
 int previous=0;for(int i=0;i<cb->order;i++){if(x[i]-previous<cb->deltaMin_Q15[i])return 0;previous=x[i];}return 32768-previous>=cb->deltaMin_Q15[cb->order];
}
static int sf_frame(FrameState *state,silk_decoder_state *ref,ec_dec *ec,unsigned mode,unsigned vad,unsigned lbrr,unsigned cond){
 int n=state->fs*state->subfr*5,lost=mode==1||(mode==2&&!lbrr);ref->VAD_flags[0]=vad;ref->LBRR_flags[0]=lbrr;ref->nFramesDecoded=0;
 ec_dec a=*ec,b=*ec;int16_t x[322],y[322];for(int i=0;i<322;i++)x[i]=y[i]=-12345;
 FrameGuard guard;memset(&guard,0xa5,sizeof(guard));guard.before=0x13579bdf98765432ULL;guard.after=0x2468ace012345678ULL;guard.value=*state;FrameWork work;memset(&work,0xa5,sizeof(work));work.before=guard.before;work.after=guard.after;
 Frame r={&guard.value,lost?NULL:&b,y+1,work.value,mode,vad,lbrr,cond,3908,lost?0:64,n,5360},saved=r;int valid=1;
 if(!lost){silk_decoder_state probe=*ref;ec_dec probe_ec=a;silk_decode_indices(&probe,&probe_ec,0,mode,cond);int16_t nlsf[16];silk_NLSF_decode(nlsf,probe.indices.NLSFIndices,probe.psNLSF_CB);valid=sf_valid(nlsf,probe.psNLSF_CB);}
 int count=op_silk_decode_frame(&r);
 if(!valid){
  if(count||guard.value.error!=1){puts("Frame invalid normative NLSF not rejected");return 0;}FrameState failed=guard.value;ec_dec failed_ec=b;int16_t failed_pcm[322];unsigned char failed_work[5360];memcpy(failed_pcm,y,sizeof(y));memcpy(failed_work,work.value,sizeof(failed_work));
  if(op_silk_decode_frame(&r)||memcmp(&guard.value,&failed,sizeof(failed))||memcmp(&b,&failed_ec,sizeof(b))||memcmp(y,failed_pcm,sizeof(y))||memcmp(work.value,failed_work,sizeof(failed_work))){puts("Frame failure not sticky");return 0;}
  sf_late++;return sf_init(state,ref,state->fs,state->subfr);
 }
 int previous_loss=ref->lossCnt;int32_t reference_n=-1;int result=silk_decode_frame(ref,lost?NULL:&a,x+1,&reference_n,mode,cond);FrameGuard expected=guard;sf_map(&expected.value,ref);
 if(result||count!=n||reference_n!=n||memcmp(x,y,sizeof(x))||memcmp(&guard,&expected,sizeof(guard))||memcmp(&a,&b,sizeof(a))||memcmp(&r,&saved,sizeof(r))||work.before!=guard.before||work.after!=guard.after){
  printf("SILK frame%u fs%d subfr%d mode%u vad%u lbrr%u cond%u count%d/%d loss%d\n",sf_frames,state->fs,state->subfr,mode,vad,lbrr,cond,count,reference_n,previous_loss);
  for(int i=0;i<n;i++)if(x[i+1]!=y[i+1]){printf("PCM%d %d/%d\n",i,x[i+1],y[i+1]);break;}
  const unsigned char *u=(const unsigned char *)&expected.value,*v=(const unsigned char *)&guard.value;for(unsigned i=0;i<sizeof(FrameState);i++)if(u[i]!=v[i]){printf("State byte%u %u/%u\n",i,u[i],v[i]);break;}return 0;
 }
 if(lost)sf_losses++;else{if(mode==2)sf_fec++;if(ref->indices.signalType==2)sf_voiced++;if(previous_loss)sf_recovered++;}
 *state=guard.value;*ec=b;sf_frames++;sf_samples+=n;sf_state_bytes+=3908;return 1;
}
static int sf_sequences(void){
 const int rates[]={8,12,16};unsigned char payload[1275];
 for(int rate=0;rate<3;rate++)for(int subfr=2;subfr<=4;subfr+=2)for(unsigned trial=0;trial<512;trial++){
  FrameState state;silk_decoder_state ref;int fs=rates[rate],current_subfr=subfr;if(!sf_init(&state,&ref,fs,subfr))return 0;
  for(unsigned frame=0;frame<16;frame++){
   if(trial%4==0&&frame%3==0){fs=rates[(rate+frame/3)%3];current_subfr=(subfr/2+frame/3)%2?2:4;if(!sf_config(&state,&ref,fs,current_subfr))return 0;}
   if(frame==8&&trial%7==0&&!sf_init(&state,&ref,fs,current_subfr))return 0;
   unsigned len=trial%7==0?0:trial%7==1?1:trial%7==2?1275:next()%1276;for(unsigned i=0;i<len;i++)payload[i]=(unsigned char)(trial%8==0?0:trial%8==1?255:next());
   ec_dec ec;memset(&ec,0,sizeof(ec));ec_dec_init(&ec,payload,len);if(trial%3==0)ec_dec_bit_logp(&ec,3);
   unsigned mode=frame%6<2?0:frame%6==2?2:frame%6<5?1:2,vad=(trial+frame)%2,lbrr=(trial/2+frame)%2,cond=(trial+frame)%3;
   if(!sf_frame(&state,&ref,&ec,mode,vad,lbrr,cond))return 0;
  }
 }return 1;
}
static int sf_continuous(void){
 const int rates[]={8,12,16};unsigned char payload[1275];
 for(unsigned trial=0;trial<2048;trial++){
  int fs=rates[trial%3],subfr=trial%2?2:4;FrameState state;silk_decoder_state ref;if(!sf_init(&state,&ref,fs,subfr))return 0;ec_dec ec;
  for(unsigned f=0;f<9;f++){
   if(f%3==0){unsigned len=trial%4==0?0:trial%4==1?1:trial%4==2?1275:next()%1276;for(unsigned i=0;i<len;i++)payload[i]=(unsigned char)next();memset(&ec,0,sizeof(ec));ec_dec_init(&ec,payload,len);fs=rates[(trial+f/3)%3];subfr=(trial+f/3)%2?2:4;if(!sf_config(&state,&ref,fs,subfr))return 0;}
   unsigned mode=f<3?0:f<6?2:f==6?1:0,lbrr=(trial+f)%2,vad=(trial/2+f)%2,cond=f%3?2:0;
   if(!sf_frame(&state,&ref,&ec,mode,vad,lbrr,cond))return 0;sf_continued++;
  }
 }return 1;
}
static int sf_sticky(void){
 unsigned char payload[1275]={0};
 for(unsigned k=0;k<5;k++){
  FrameState state;silk_decoder_state ref;if(!sf_init(&state,&ref,16,4))return 0;
  switch(k){case 0:state.param.prev[15]=-1;break;case 1:state.plc.last_frame_lost=2;break;case 2:state.cng.fs_kHz=16;state.cng.CNG_smth_Gain_Q16=-1;break;case 3:state.cng.fs_kHz=16;state.cng.CNG_smth_NLSF_Q15[15]=-1;break;case 4:state.plc.fs_kHz=16;state.plc.pitchL_Q8=0;break;}
  ec_dec ec;memset(&ec,0,sizeof(ec));ec_dec_init(&ec,payload,sizeof(payload));int16_t pcm[320];unsigned char work[5360];memset(pcm,0xa5,sizeof(pcm));memset(work,0xa5,sizeof(work));Frame r={&state,k==4?NULL:&ec,pcm,work,k==4?1:0,0,0,0,3908,k==4?0:64,320,5360};
  if(op_silk_decode_frame(&r)||state.error!=1){printf("Frame sticky trigger%u\n",k);return 0;}FrameState failed=state;ec_dec failed_ec=ec;int16_t failed_pcm[320];unsigned char failed_work[5360];memcpy(failed_pcm,pcm,sizeof(pcm));memcpy(failed_work,work,sizeof(work));
  if(op_silk_decode_frame(&r)||memcmp(&state,&failed,sizeof(state))||memcmp(&ec,&failed_ec,sizeof(ec))||memcmp(pcm,failed_pcm,sizeof(pcm))||memcmp(work,failed_work,sizeof(work))){printf("Frame sticky reuse%u\n",k);return 0;}FrameInit config={&state,8,2,3908};if(op_silk_frame_config(&config)||memcmp(&state,&failed,sizeof(state)))return 0;
  if(!sf_init(&state,&ref,16,4))return 0;memset(&ec,0,sizeof(ec));ec_dec_init(&ec,payload,sizeof(payload));if(!sf_frame(&state,&ref,&ec,0,0,0,0))return 0;sf_late++;
 }return 1;
}
static int sf_invalid(void){
 FrameState state;silk_decoder_state ref;if(!sf_init(&state,&ref,16,4))return 0;FrameInit ib={&state,16,4,3908};
 for(unsigned operation=0;operation<2;operation++)for(unsigned k=0;k<(operation?12:8);k++){
  FrameInit r=ib;FrameState original=state;switch(k){case 0:r.state=NULL;break;case 1:r.fs=0;break;case 2:r.fs=24;break;case 3:r.subfr=0;break;case 4:r.subfr=3;break;case 5:r.cap=3907;break;case 6:r.fs=-1;break;case 7:r.subfr=-1;break;case 8:state.tag=0;break;case 9:state.error=1;break;case 10:state.fs=0;break;case 11:state.subfr=0;break;}
  FrameInit saved=r;FrameState prior=state;int count=operation?op_silk_frame_config(&r):op_silk_frame_init(&r);if(count||memcmp(&state,&prior,sizeof(state))||memcmp(&r,&saved,sizeof(r))){printf("Frame init/config guard%u/%u\n",operation,k);return 0;}state=original;sf_guards++;
 }
 unsigned char payload[1275]={0};ec_dec ec;memset(&ec,0,sizeof(ec));ec_dec_init(&ec,payload,sizeof(payload));int16_t pcm[320];unsigned char work[5360];memset(pcm,0xa5,sizeof(pcm));memset(work,0xa5,sizeof(work));Frame base={&state,&ec,pcm,work,0,0,0,0,3908,64,320,5360};
 for(unsigned k=0;k<40;k++){
  Frame r=base;FrameState original_state=state;ec_dec original_ec=ec;
  switch(k){case 0:r.state=NULL;break;case 1:r.ec=NULL;break;case 2:r.pcm=NULL;break;case 3:r.work=NULL;break;case 4:r.mode=3;break;case 5:r.vad=2;break;case 6:r.lbrr=2;break;case 7:r.cond=3;break;case 8:r.state_cap=3907;break;case 9:r.ec_cap=63;break;case 10:r.pcm_cap=319;break;case 11:r.work_cap=5359;break;case 12:state.fs=24;break;case 13:state.subfr=3;break;case 14:state.tag=0;break;case 15:state.error=1;break;case 16:state.core.gain=0;break;case 17:state.core.signal=3;break;case 18:state.core.loss=-1;break;case 19:state.param.first=2;break;case 20:state.param.gain=64;break;case 21:state.previous.signal=3;break;case 22:state.previous.lag=32768;break;case 23:state.previous.lag=-32769;break;case 24:ec.buf=NULL;break;case 25:ec.storage=1276;break;case 26:ec.end_offs=1276;break;case 27:ec.offs=1276;break;case 28:ec.rng=0x800000;break;case 29:ec.rng=0x80000001;break;case 30:ec.val=ec.rng;break;case 31:ec.nend_bits=33;break;case 32:ec.nbits_total=32769;break;case 33:r.mode=1;state.core.loss=INT32_MAX;break;case 34:r.mode=2;r.lbrr=1;r.ec=NULL;break;case 35:state.core.gain=-1;break;case 36:state.core.signal=-1;break;case 37:r.mode=UINT32_MAX;break;case 38:r.vad=UINT32_MAX;break;case 39:r.cond=UINT32_MAX;break;}
  FrameState prior_state=state;ec_dec prior_ec=ec;Frame saved=r;int16_t prior_pcm[320];unsigned char prior_work[5360];memcpy(prior_pcm,pcm,sizeof(pcm));memcpy(prior_work,work,sizeof(work));
  if(op_silk_decode_frame(&r)||memcmp(&state,&prior_state,sizeof(state))||memcmp(&ec,&prior_ec,sizeof(ec))||memcmp(&r,&saved,sizeof(r))||memcmp(pcm,prior_pcm,sizeof(pcm))||memcmp(work,prior_work,sizeof(work))){printf("Frame guard%u\n",k);return 0;}state=original_state;ec=original_ec;sf_guards++;
 }
 if(op_silk_decode_frame(NULL)||op_silk_frame_init(NULL)||op_silk_frame_config(NULL))return 0;sf_guards+=3;return 1;
}
#ifndef SILK_FRAME_ORACLE_EMBEDDED
int main(void){if(!sf_sequences()||!sf_continuous()||!sf_sticky()||!sf_invalid())return 1;printf("SILK frame: %u initializations, %u configurations (%u rate changes), %u exact entropy-to-PCM/history frames (%u lost, %u FEC, %u voiced, %u recovered, %u continued entropy), %llu int16 PCM samples, %llu full-history bytes, %u late component/sticky/reset checks, %u guards\n",sf_initializations,sf_configurations,sf_rate_changes,sf_frames,sf_losses,sf_fec,sf_voiced,sf_recovered,sf_continued,sf_samples,sf_state_bytes,sf_late,sf_guards);return 0;}
#endif
