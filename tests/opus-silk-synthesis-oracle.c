/* Test-only complete inverse-NSQ core, connected parameters/pulses and history. */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "main.h"
#include "tables.h"
typedef struct {int32_t gain,exc[320],lpc[16];int16_t out[480];int lag,signal,loss;} Core;
typedef struct {Core *state;silk_decoder_control *ctrl;const SideInfoIndices *ind;const int *pulses;int16_t *pcm;void *work;int fs,subfr;unsigned state_cap,ctrl_cap,pulse_cap,pcm_cap,work_cap,ind_cap;} Synthesis;
typedef struct {int8_t gain;unsigned char padding[3];int16_t prev[16];int first,loss;uint32_t reserved;} ParamState;
typedef struct {SideInfoIndices *ind;ParamState *state;silk_decoder_control *out;int fs,subfr,cond;unsigned ind_cap,state_cap,out_cap;} Parameters;
typedef struct {int lag,signal;} Previous;
typedef struct {ec_dec *ec;Previous *state;SideInfoIndices *out;int fs,subfr,vad,lbrr,cond;unsigned out_cap,state_cap;} Indices;
int op_silk_synthesis(Synthesis *);
int op_silk_decode_parameters(Parameters *);
int op_silk_indices(Indices *);
int op_silk_pulses(ec_dec *,int *,unsigned,unsigned,unsigned);
typedef char core_size[(sizeof(Core)==2320)?1:-1];
typedef char request_size[(sizeof(Synthesis)==80)?1:-1];
static uint32_t rng=0xcb4621af;
static uint32_t next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static unsigned frames,connected_frames,voiced_frames,blend_frames,interpolated_frames,gain_changes,clipped_samples,invalid_nlsf,guards;
static unsigned long long samples,history_values;
typedef struct {uint64_t before;Core value;uint64_t after;} CoreGuard;
typedef struct {uint64_t before;unsigned char value[3936];uint64_t after;} WorkGuard;
static void configure(silk_decoder_state *s,int fs,int subfr){
 memset(s,0,sizeof(*s));s->fs_kHz=fs;s->nb_subfr=subfr;s->LPC_order=fs==16?16:10;
 s->frame_length=fs*subfr*5;s->subfr_length=fs*5;s->ltp_mem_length=fs*20;
 s->psNLSF_CB=fs==16?&silk_NLSF_CB_WB:&silk_NLSF_CB_NB_MB;
 s->pitch_lag_low_bits_iCDF=fs==8?silk_uniform4_iCDF:fs==12?silk_uniform6_iCDF:silk_uniform8_iCDF;
 s->pitch_contour_iCDF=fs==8?(subfr==2?silk_pitch_contour_10_ms_NB_iCDF:silk_pitch_contour_NB_iCDF):(subfr==2?silk_pitch_contour_10_ms_iCDF:silk_pitch_contour_iCDF);
}
static void init(Core *core,ParamState *param,silk_decoder_control *ctrl,int fs,unsigned pattern){
 memset(core,0xa5,sizeof(*core));memset(param,0xa5,sizeof(*param));memset(ctrl,0xa5,sizeof(*ctrl));
 core->gain=pattern%4==0?65536:pattern%4==1?1:pattern%4==2?INT32_MAX:65536+(next()%10000000);
 core->lag=fs*5;core->signal=pattern%3;core->loss=pattern%5==0?1:0;
 for(int i=0;i<16;i++)core->lpc[i]=pattern%8==0?(int32_t)next():pattern%8==1?INT32_MIN:pattern%8==2?INT32_MAX:(int32_t)(next()%65536)-32768;
 for(int i=0;i<480;i++)core->out[i]=(int16_t)(pattern%8==0?0:pattern%8==1?INT16_MAX:pattern%8==2?INT16_MIN:next());
 int order=fs==16?16:10;param->gain=(int8_t)(next()%64);param->first=1;param->loss=0;
 for(int i=0;i<order;i++)param->prev[i]=(int16_t)((i+1)*32768/(order+1));
}
static int core_frame(Core *core,silk_decoder_control *ctrl,SideInfoIndices *ind,const int *pulses,int fs,int subfr){
 int n=fs*subfr*5;silk_decoder_state reference;configure(&reference,fs,subfr);
 reference.prev_gain_Q16=core->gain;memcpy(reference.exc_Q14,core->exc,sizeof(core->exc));memcpy(reference.sLPC_Q14_buf,core->lpc,sizeof(core->lpc));memcpy(reference.outBuf,core->out,sizeof(core->out));
 reference.lagPrev=core->lag;reference.prevSignalType=core->signal;reference.lossCnt=core->loss;reference.indices=*ind;
 silk_decoder_control expected=*ctrl;int16_t a[322],b[322];for(int i=0;i<322;i++)a[i]=b[i]=-12345;
 int saved_pulses[320];memcpy(saved_pulses,pulses,sizeof(saved_pulses));SideInfoIndices saved_ind=*ind;
 CoreGuard cg;cg.before=0x13579bdf98765432ULL;cg.after=0x2468ace012345678ULL;cg.value=*core;
 WorkGuard wg;memset(&wg,0xa5,sizeof(wg));wg.before=cg.before;wg.after=cg.after;
 Synthesis request={&cg.value,ctrl,ind,pulses,b+1,wg.value,fs,subfr,2320,140,n,n,3936,36},saved=request;
 silk_decode_core(&reference,&expected,a+1,pulses);
 int ok=op_silk_synthesis(&request);
 Core expected_core=*core;expected_core.gain=reference.prev_gain_Q16;memcpy(expected_core.exc,reference.exc_Q14,sizeof(core->exc));memcpy(expected_core.lpc,reference.sLPC_Q14_buf,sizeof(core->lpc));memcpy(expected_core.out,reference.outBuf,sizeof(core->out));
 if(!ok||memcmp(a,b,sizeof(a))||memcmp(ctrl,&expected,sizeof(expected))||memcmp(&cg.value,&expected_core,sizeof(expected_core))||memcmp(ind,&saved_ind,sizeof(saved_ind))||memcmp(pulses,saved_pulses,sizeof(saved_pulses))||memcmp(&request,&saved,sizeof(request))||cg.before!=0x13579bdf98765432ULL||cg.after!=0x2468ace012345678ULL||wg.before!=cg.before||wg.after!=cg.after){
  printf("Core mismatch frame=%u fs=%d subfr=%d signal=%d interp=%d previous=%d loss=%d ok=%d\n",frames,fs,subfr,ind->signalType,ind->NLSFInterpCoef_Q2,core->signal,core->loss,ok);
  for(int i=0;i<n;i++)if(a[i+1]!=b[i+1]){printf("PCM%d %d/%d\n",i,a[i+1],b[i+1]);break;}
  for(int i=0;i<16;i++)if(expected_core.lpc[i]!=cg.value.lpc[i])printf("LPC%d %d/%d\n",i,expected_core.lpc[i],cg.value.lpc[i]);return 0;
 }
 if(ind->signalType==2)voiced_frames++;if(ind->NLSFInterpCoef_Q2<4)interpolated_frames++;if(core->loss&&core->signal==2&&ind->signalType!=2)blend_frames++;
 for(int i=0;i<subfr;i++)if(expected.Gains_Q16[i]!=(i?expected.Gains_Q16[i-1]:core->gain))gain_changes++;
 for(int i=0;i<n;i++)if(b[i+1]==INT16_MAX||b[i+1]==INT16_MIN)clipped_samples++;
 *core=cg.value;frames++;samples+=n;history_values+=320+16+480+4;
 /* Core-only sequence: mirror frame-history maintenance, excluding PLC/CNG. */
 int mem=fs*20;memmove(core->out,core->out+n,(mem-n)*2);memcpy(core->out+mem-n,b+1,n*2);
 core->lag=ctrl->pitchL[subfr-1];core->signal=ind->signalType;core->loss=0;return 1;
}
static int parameters(SideInfoIndices *ind,ParamState *param,silk_decoder_control *ctrl,int fs,int subfr,int cond){
 Parameters r={ind,param,ctrl,fs,subfr,cond,36,48,140};
 if(!op_silk_decode_parameters(&r)){invalid_nlsf++;return 0;}return 1;
}
static int standalone(void){
 const int rates[]={8,12,16};
 for(int r=0;r<3;r++)for(int subfr=2;subfr<=4;subfr+=2)for(unsigned trial=0;trial<512;trial++){
  int fs=rates[r],order=fs==16?16:10,n=fs*subfr*5;Core core;ParamState param;silk_decoder_control ctrl;init(&core,&param,&ctrl,fs,trial);
  for(int frame=0;frame<4;frame++){
   SideInfoIndices ind;memset(&ind,0xa5,sizeof(ind));int cond=(trial+frame)%3;
   ind.signalType=(int8_t)((trial+frame)%3);ind.quantOffsetType=(int8_t)((trial/3+frame)%2);ind.Seed=(int8_t)((trial+frame)%4);ind.NLSFInterpCoef_Q2=(int8_t)((trial+frame)%5);
   ind.NLSFIndices[0]=(int8_t)(next()%32);for(int i=1;i<=order;i++)ind.NLSFIndices[i]=(int8_t)((int)(next()%7)-3);
   for(int i=0;i<subfr;i++)ind.GainsIndices[i]=(int8_t)(next()%(i==0&&cond!=2?64:41));
   ind.PERIndex=(int8_t)(next()%3);ind.LTP_scaleIndex=(int8_t)(next()%3);ind.lagIndex=(int16_t)(next()%(fs*16+1));ind.contourIndex=(int8_t)(next()%(fs==8?(subfr==2?3:11):(subfr==2?12:34)));
   for(int i=0;i<subfr;i++)ind.LTPIndex[i]=(int8_t)(next()%(8<<ind.PERIndex));
   param.first=frame==0;param.loss=trial%8==0?1:0;
   if(!parameters(&ind,&param,&ctrl,fs,subfr,cond))continue;
   int pulses[320];for(int i=0;i<320;i++)pulses[i]=i<n?(trial%8==0?0:trial%8==1?32767:trial%8==2?-32768:trial%8==3?(i%2?32767:-32768):(int)(next()%33)-16):0x13579bdf;
   if(trial%5==0){core.loss=1;core.signal=2;core.lag=fs*5;}
   if(!core_frame(&core,&ctrl,&ind,pulses,fs,subfr))return 0;
  }
 }
 return 1;
}
static int connected(void){
 const int rates[]={8,12,16};unsigned char payload[1275];
 for(unsigned trial=0;trial<2048;trial++){
  int fs=rates[trial%3],subfr=trial%2?2:4,n=fs*subfr*5;
  Core core;ParamState param;silk_decoder_control ctrl;init(&core,&param,&ctrl,fs,trial);
  silk_decoder_state ref;configure(&ref,fs,subfr);ref.ec_prevLagIndex=100;ref.ec_prevSignalType=2;Previous previous={100,2};SideInfoIndices ind;memset(&ind,0xa5,sizeof(ind));ref.indices=ind;
  for(int frame=0;frame<4;frame++){
   unsigned len=trial%8==0?0:trial%8==1?1:trial%8==2?1275:next()%1276;for(unsigned i=0;i<len;i++)payload[i]=(unsigned char)next();
   ec_dec ea,eb;memset(&ea,0,sizeof(ea));ec_dec_init(&ea,payload,len);eb=ea;
   if(trial%3==0){ec_dec_bit_logp(&ea,3);ec_dec_bit_logp(&eb,3);}
   int vad=(trial+frame)%2,lbrr=(trial/2+frame)%2,cond=(trial+frame)%3;ref.VAD_flags[frame%3]=vad;
   silk_decode_indices(&ref,&ea,frame%3,lbrr,cond);Indices ir={&eb,&previous,&ind,fs,subfr,vad,lbrr,cond,36,8};
   if(!op_silk_indices(&ir)||memcmp(&ind,&ref.indices,sizeof(ind))||memcmp(&ea,&eb,sizeof(ea))){printf("Connected indices trial=%u frame=%d\n",trial,frame);return 0;}
   int a[320],b[320];for(int i=0;i<320;i++)a[i]=b[i]=0x13579bdf;
   silk_decode_pulses(&ea,a,ind.signalType,ind.quantOffsetType,n);
   if(!op_silk_pulses(&eb,b,ind.signalType,ind.quantOffsetType,n)||memcmp(a,b,sizeof(a))||memcmp(&ea,&eb,sizeof(ea))){printf("Connected pulses trial=%u frame=%d\n",trial,frame);return 0;}
   param.first=frame==0;param.loss=0;
   if(!parameters(&ind,&param,&ctrl,fs,subfr,cond))continue;
   ref.indices=ind; /* Normative parameter stage resets PER/interpolation too. */
   if(!core_frame(&core,&ctrl,&ind,b,fs,subfr))return 0;connected_frames++;
  }
 }
 return 1;
}
static int invalid(void){
 Core core;ParamState param;silk_decoder_control ctrl;init(&core,&param,&ctrl,16,0);SideInfoIndices ind;memset(&ind,0,sizeof(ind));ind.signalType=2;ind.NLSFInterpCoef_Q2=4;
 for(int i=0;i<4;i++){ctrl.pitchL[i]=100;ctrl.Gains_Q16[i]=65536;}ctrl.LTP_scale_Q14=8192;
 int pulses[320]={0};int16_t pcm[320];unsigned char work[3936];memset(pcm,0xa5,sizeof(pcm));memset(work,0xa5,sizeof(work));
 Synthesis base={&core,&ctrl,&ind,pulses,pcm,work,16,4,2320,140,320,320,3936,36};
 for(unsigned i=0;i<35;i++){
  Synthesis req=base;Core prior_core=core;silk_decoder_control prior_ctrl=ctrl;SideInfoIndices prior_ind=ind;int prior_pulses[320];memcpy(prior_pulses,pulses,sizeof(pulses));
  switch(i){case 0:req.state=NULL;break;case 1:req.ctrl=NULL;break;case 2:req.ind=NULL;break;case 3:req.pulses=NULL;break;case 4:req.pcm=NULL;break;case 5:req.work=NULL;break;case 6:req.fs=24;break;case 7:req.subfr=3;break;case 8:req.state_cap=2319;break;case 9:req.ctrl_cap=139;break;case 10:req.pulse_cap=319;break;case 11:req.pcm_cap=319;break;case 12:req.work_cap=3935;break;case 13:req.ind_cap=35;break;case 14:core.gain=0;break;case 15:core.gain=-1;break;case 16:core.signal=3;break;case 17:core.loss=-1;break;case 18:ind.signalType=3;break;case 19:ind.quantOffsetType=2;break;case 20:ind.NLSFInterpCoef_Q2=5;break;case 21:ind.Seed=4;break;case 22:ctrl.LTP_scale_Q14=-1;break;case 23:ctrl.LTP_scale_Q14=16385;break;case 24:ctrl.pitchL[3]=31;break;case 25:ctrl.pitchL[3]=289;break;case 26:ctrl.pitchL[0]=32;ctrl.pitchL[1]=113;break;case 27:ctrl.Gains_Q16[3]=0;break;case 28:pulses[319]=32768;break;case 29:pulses[0]=-32769;break;case 30:ind.signalType=0;core.loss=1;core.signal=2;core.lag=31;break;case 31:ind.signalType=0;core.loss=1;core.signal=2;core.lag=289;break;case 32:req.fs=0;break;case 33:req.subfr=0;break;case 34:ctrl.Gains_Q16[0]=-1;break;}
  Synthesis saved=req;Core changed_core=core;silk_decoder_control changed_ctrl=ctrl;SideInfoIndices changed_ind=ind;int16_t prior_pcm[320];unsigned char prior_work[3936];memcpy(prior_pcm,pcm,sizeof(pcm));memcpy(prior_work,work,sizeof(work));
  if(op_silk_synthesis(&req)||memcmp(&req,&saved,sizeof(req))||memcmp(&core,&changed_core,sizeof(core))||memcmp(&ctrl,&changed_ctrl,sizeof(ctrl))||memcmp(&ind,&changed_ind,sizeof(ind))||memcmp(pcm,prior_pcm,sizeof(pcm))||memcmp(work,prior_work,sizeof(work))){printf("Core guard %u\n",i);return 0;}
  core=prior_core;ctrl=prior_ctrl;ind=prior_ind;memcpy(pulses,prior_pulses,sizeof(pulses));guards++;
 }
 if(op_silk_synthesis(NULL))return 0;guards++;return 1;
}
int main(void){
 if(!standalone()){puts("Standalone core failed");return 1;}
 if(!connected()){puts("Connected core failed");return 1;}
 if(!invalid()){puts("Core guards failed");return 1;}
 printf("SILK synthesis: %u exact source-rate PCM/history frames (%u connected indices/pulses, %u voiced, %u interpolated, %u voiced-loss-to-unvoiced blends), %u gain changes, %llu int16 PCM samples (%u clipped), %llu history values, %u invalid NLSF parameter skips, %u guards\n",frames,connected_frames,voiced_frames,interpolated_frames,blend_frames,gain_changes,samples,clipped_samples,history_values,invalid_nlsf,guards);
 return 0;
}
