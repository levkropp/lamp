/* Test-only normative CNG state/PCM, using the verified core harness. */
#define main silk_synthesis_oracle_main
#include "opus-silk-synthesis-oracle.c"
#undef main
#include "resampler_private.h"
typedef struct {silk_CNG_struct *state;const Core *core;const ParamState *param;const silk_decoder_control *ctrl;int16_t *pcm;void *work;int fs,subfr,n;unsigned state_cap,core_cap,param_cap,ctrl_cap,pcm_cap,work_cap;} Cng;
typedef struct {silk_resampler_state_struct *state;int in,out;unsigned cap;} ResampleInit;
typedef struct {silk_resampler_state_struct *state;int16_t *out;const int16_t *in;void *work;unsigned n,in_cap,out_cap,state_cap,work_cap;} Resample;
int op_silk_cng(Cng *);
int op_silk_resampler_init(ResampleInit *);
int op_silk_resampler(Resample *);
typedef char cng_size[(sizeof(silk_CNG_struct)==1388&&sizeof(Cng)==88)?1:-1];
typedef struct {uint64_t before;silk_CNG_struct value;uint64_t after;} CngGuard;
typedef struct {uint64_t before;unsigned char value[1376];uint64_t after;} CngWork;
static uint32_t cn_rng=0x81f46d23;
static uint32_t cn_next(void){cn_rng^=cn_rng<<13;cn_rng^=cn_rng>>17;cn_rng^=cn_rng<<5;return cn_rng;}
static unsigned cn_frames,cn_updates,cn_losses,cn_resets,cn_connected,cn_guards;
static unsigned long long cn_samples,cn_history,cn_resampled;
static int cn_frame(silk_CNG_struct *state,const Core *core,const ParamState *param,const silk_decoder_control *ctrl,int16_t *pcm,int fs,int subfr,int n){
 silk_decoder_state reference;configure(&reference,fs,subfr);reference.sCNG=*state;reference.lossCnt=core->loss;reference.prevSignalType=core->signal;
 memcpy(reference.exc_Q14,core->exc,sizeof(core->exc));memcpy(reference.prevNLSF_Q15,param->prev,sizeof(param->prev));
 silk_decoder_control reference_ctrl=*ctrl;int16_t x[322],y[322];x[0]=y[0]=x[321]=y[321]=-12345;memcpy(x+1,pcm,640);memcpy(y+1,pcm,640);
 Core saved_core=*core;ParamState saved_param=*param;silk_decoder_control saved_ctrl=*ctrl;
 CngGuard guard;memset(&guard,0xa5,sizeof(guard));guard.before=0x13579bdf98765432ULL;guard.after=0x2468ace012345678ULL;guard.value=*state;
 CngWork work;memset(&work,0xa5,sizeof(work));work.before=guard.before;work.after=guard.after;
 Cng r={&guard.value,core,param,ctrl,y+1,work.value,fs,subfr,n,1388,2320,48,140,n,1376},saved=r;
 silk_CNG(&reference,&reference_ctrl,x+1,n);
 if(!op_silk_cng(&r)||memcmp(x,y,sizeof(x))||memcmp(&reference.sCNG,&guard.value,sizeof(guard.value))||memcmp(core,&saved_core,sizeof(*core))||memcmp(param,&saved_param,sizeof(*param))||memcmp(ctrl,&saved_ctrl,sizeof(*ctrl))||memcmp(&r,&saved,sizeof(r))||guard.before!=0x13579bdf98765432ULL||guard.after!=0x2468ace012345678ULL||work.before!=guard.before||work.after!=guard.after){
  printf("CNG frame=%u fs=%d subfr=%d n=%d signal=%d loss=%d oldfs=%d\n",cn_frames,fs,subfr,n,core->signal,core->loss,state->fs_kHz);
  for(int i=0;i<n;i++)if(x[i+1]!=y[i+1]){printf("PCM%d %d/%d\n",i,x[i+1],y[i+1]);break;}
  const unsigned char *a=(const unsigned char *)&reference.sCNG,*b=(const unsigned char *)&guard.value;for(unsigned i=0;i<sizeof(guard.value);i++)if(a[i]!=b[i]){printf("CNG state byte%u %u/%u\n",i,a[i],b[i]);break;}return 0;
 }
 if(state->fs_kHz!=fs)cn_resets++;if(core->loss)cn_losses++;else if(!core->signal)cn_updates++;
 *state=guard.value;memcpy(pcm,y+1,640);cn_frames++;cn_samples+=n;cn_history+=355;return 1;
}
static void cn_initialize(silk_CNG_struct *state,Core *core,ParamState *param,silk_decoder_control *ctrl,int fs,unsigned pattern){
 init(core,param,ctrl,fs,pattern);memset(state,0xa5,sizeof(*state));state->fs_kHz=pattern%4==0?0:fs;
 state->CNG_smth_Gain_Q16=pattern%8==0?0:pattern%8==1?INT32_MAX:(int32_t)(cn_next()&INT32_MAX);state->rand_seed=(int32_t)cn_next();
 for(int i=0;i<320;i++){state->CNG_exc_buf_Q14[i]=(int32_t)cn_next();core->exc[i]=(int32_t)cn_next();}
 for(int i=0;i<16;i++){state->CNG_smth_NLSF_Q15[i]=(int16_t)(cn_next()%32768);state->CNG_synth_state[i]=(int32_t)cn_next();}
 for(int i=0;i<4;i++)ctrl->Gains_Q16[i]=pattern%4==0?1:pattern%4==1?INT32_MAX:1+(int32_t)(cn_next()&0x3fffffff);
 for(int i=0;i<(fs==16?16:10);i++)param->prev[i]=(int16_t)(cn_next()%32768);
}
static int cn_standalone(void){
 const int rates[]={8,12,16};
 for(int r=0;r<3;r++)for(int subfr=2;subfr<=4;subfr+=2)for(unsigned trial=0;trial<1024;trial++){
  int fs=rates[r];silk_CNG_struct state;Core core;ParamState param;silk_decoder_control ctrl;cn_initialize(&state,&core,&param,&ctrl,fs,trial);
  for(unsigned frame=0;frame<8;frame++){
   if(frame%3==0)fs=rates[(r+frame/3)%3];int order=fs==16?16:10,full=fs*subfr*5;
   for(int i=0;i<order;i++)param.prev[i]=(int16_t)(cn_next()%32768);
   core.signal=(trial+frame)%3;core.loss=frame%4==0?0:frame%4;
   int n=frame%4==0?full:frame%4==1?1:frame%4==2?order:1+cn_next()%full;int16_t pcm[320];
   for(int i=0;i<320;i++)pcm[i]=(int16_t)(trial%5==0?0:trial%5==1?INT16_MAX:trial%5==2?INT16_MIN:cn_next());
   if(!cn_frame(&state,&core,&param,&ctrl,pcm,fs,subfr,n))return 0;
  }
 }
 return 1;
}
static int cn_connected_frames(void){
 const int rates[]={8,12,16};
 for(int r=0;r<3;r++)for(int subfr=2;subfr<=4;subfr+=2)for(unsigned trial=0;trial<128;trial++){
  int fs=rates[r],order=fs==16?16:10,n=fs*subfr*5;Core core;ParamState param;silk_decoder_control ctrl;init(&core,&param,&ctrl,fs,trial);
  silk_CNG_struct state;memset(&state,0,sizeof(state));silk_resampler_state_struct ra,rb;silk_resampler_init(&ra,fs*1000,48000,0);ResampleInit ri={&rb,fs*1000,48000,304};if(!op_silk_resampler_init(&ri))return 0;
  for(int frame=0;frame<12;frame++){
   int16_t pcm[320];memset(pcm,0,sizeof(pcm));
   if(frame%6<4){
    SideInfoIndices ind;memset(&ind,0xa5,sizeof(ind));int cond=(trial+frame)%3;
    ind.signalType=(int8_t)(frame%6<3?0:(trial%2?1:2));ind.quantOffsetType=(int8_t)((trial+frame)%2);ind.Seed=(int8_t)((trial+frame)%4);ind.NLSFInterpCoef_Q2=(int8_t)((trial+frame)%5);
    ind.NLSFIndices[0]=(int8_t)(cn_next()%32);for(int i=1;i<=order;i++)ind.NLSFIndices[i]=(int8_t)((int)(cn_next()%7)-3);
    for(int i=0;i<subfr;i++)ind.GainsIndices[i]=(int8_t)(cn_next()%(i==0&&cond!=2?64:41));
    ind.PERIndex=(int8_t)(cn_next()%3);ind.LTP_scaleIndex=(int8_t)(cn_next()%3);ind.lagIndex=(int16_t)(cn_next()%(fs*16+1));ind.contourIndex=(int8_t)(cn_next()%(fs==8?(subfr==2?3:11):(subfr==2?12:34)));
    for(int i=0;i<subfr;i++)ind.LTPIndex[i]=(int8_t)(cn_next()%(8<<ind.PERIndex));param.first=frame==0;param.loss=core.loss;
    if(!parameters(&ind,&param,&ctrl,fs,subfr,cond))continue;
    int pulses[320];for(int i=0;i<320;i++)pulses[i]=i<n?(int)(cn_next()%33)-16:0x13579bdf;
    if(!core_frame(&core,&ctrl,&ind,pulses,fs,subfr))return 0;memcpy(pcm,core.out+fs*20-n,n*2);
   }else core.loss++; /* Isolated CNG on lost frames; full PLC remains separate. */
   if(!cn_frame(&state,&core,&param,&ctrl,pcm,fs,subfr,n))return 0;
   int16_t x[960],y[960];unsigned char work[736];int count=subfr*5*48;for(int i=0;i<960;i++)x[i]=y[i]=-12345;
   Resample rr={&rb,y,pcm,work,n,n,count,304,736};if(silk_resampler(&ra,x,pcm,n)||op_silk_resampler(&rr)!=count||memcmp(x,y,sizeof(x))){puts("CNG connected resampling mismatch");return 0;}
   cn_connected++;cn_resampled+=count;
  }
 }
 return 1;
}
static int cn_invalid(void){
 silk_CNG_struct state;Core core;ParamState param;silk_decoder_control ctrl;cn_initialize(&state,&core,&param,&ctrl,16,3);core.loss=0;core.signal=0;
 int16_t pcm[320];unsigned char work[1376];memset(pcm,0xa5,sizeof(pcm));memset(work,0xa5,sizeof(work));
 Cng base={&state,&core,&param,&ctrl,pcm,work,16,4,320,1388,2320,48,140,320,1376};
 for(unsigned k=0;k<26;k++){
  Cng r=base;silk_CNG_struct original_state=state;Core original_core=core;ParamState original_param=param;silk_decoder_control original_ctrl=ctrl;
  switch(k){case 0:r.state=NULL;break;case 1:r.core=NULL;break;case 2:r.param=NULL;break;case 3:r.ctrl=NULL;break;case 4:r.pcm=NULL;break;case 5:r.work=NULL;break;case 6:r.fs=24;break;case 7:r.subfr=3;break;case 8:r.n=0;break;case 9:r.n=321;break;case 10:r.state_cap=1387;break;case 11:r.core_cap=2319;break;case 12:r.param_cap=47;break;case 13:r.ctrl_cap=139;break;case 14:r.pcm_cap=319;break;case 15:r.work_cap=1375;break;case 16:core.loss=-1;break;case 17:core.signal=3;break;case 18:state.CNG_smth_Gain_Q16=-1;break;case 19:state.CNG_smth_NLSF_Q15[15]=-1;break;case 20:param.prev[15]=-1;break;case 21:ctrl.Gains_Q16[3]=0;break;case 22:r.n=-1;break;case 23:r.subfr=0;break;case 24:ctrl.Gains_Q16[0]=-1;break;case 25:r.fs=0;break;}
  Cng saved=r;silk_CNG_struct prior_state=state;Core prior_core=core;ParamState prior_param=param;silk_decoder_control prior_ctrl=ctrl;int16_t prior_pcm[320];unsigned char prior_work[1376];memcpy(prior_pcm,pcm,sizeof(pcm));memcpy(prior_work,work,sizeof(work));
  if(op_silk_cng(&r)||memcmp(&r,&saved,sizeof(r))||memcmp(&state,&prior_state,sizeof(state))||memcmp(&core,&prior_core,sizeof(core))||memcmp(&param,&prior_param,sizeof(param))||memcmp(&ctrl,&prior_ctrl,sizeof(ctrl))||memcmp(pcm,prior_pcm,sizeof(pcm))||memcmp(work,prior_work,sizeof(work))){printf("CNG guard %u\n",k);return 0;}
  state=original_state;core=original_core;param=original_param;ctrl=original_ctrl;cn_guards++;
 }
 if(op_silk_cng(NULL))return 0;cn_guards++;return 1;
}
int main(void){
 if(!cn_standalone()){puts("CNG standalone failed");return 1;}
 if(!cn_connected_frames()){puts("CNG connected failed");return 1;}
 if(!cn_invalid()){puts("CNG guards failed");return 1;}
 printf("SILK CNG: %u exact PCM/history frames (%u parameter updates, %u lost frames, %u rate resets, %u connected synthesis/CNG/resampling), %llu int16 PCM samples, %llu history values, %llu connected resampled samples, %u guards\n",cn_frames,cn_updates,cn_losses,cn_resets,cn_connected,cn_samples,cn_history,cn_resampled,cn_guards);
 return 0;
}
