/* Test-only unchanged normative PLC/energy/recovery, connected to core/CNG. */
#define SILK_CNG_ORACLE_EMBEDDED
#include "lamp-test.h"
#include "opus-silk-cng-oracle.c"
#include <stddef.h>
#include "PLC.h"
typedef struct {silk_PLC_struct *state;Core *core;const ParamState *param;silk_decoder_control *ctrl;const SideInfoIndices *ind;int16_t *pcm;void *work;int fs,subfr,lost;unsigned state_cap,core_cap,param_cap,ctrl_cap,ind_cap,pcm_cap,work_cap;} Plc;
typedef struct {silk_PLC_struct *state;int16_t *pcm;int n,loss;unsigned state_cap,pcm_cap;} Glue;
typedef struct {int32_t *energy;int *shift;const int16_t *in;unsigned n,in_cap;} Energy;
LAMP_ABI int op_silk_plc(Plc *);
LAMP_ABI int op_silk_plc_glue(Glue *);
LAMP_ABI int op_silk_sum_sqr(Energy *);
typedef char plc_sizes[(sizeof(Plc)==96&&sizeof(Glue)==32&&sizeof(Energy)==32&&sizeof(silk_PLC_struct)==92&&offsetof(silk_PLC_struct,prevLPC_Q12)==14&&offsetof(silk_PLC_struct,last_frame_lost)==48&&offsetof(silk_PLC_struct,prevGain_Q16)==72&&offsetof(silk_PLC_struct,subfr_length)==88)?1:-1];
typedef struct {uint64_t before;silk_PLC_struct value;uint64_t after;} PlcGuard;
typedef struct {uint64_t before;unsigned char value[3552];uint64_t after;} PlcWork;
static unsigned pl_energy_cases,pl_frames,pl_losses,pl_updates,pl_resets,pl_glues,pl_fades,pl_connected,pl_guards;
static unsigned long long pl_samples,pl_history,pl_resampled;
static int pl_energy_tests(void){
 int16_t input[482];for(unsigned trial=0;trial<16384;trial++){
  unsigned n=trial<481?trial:next()%481;for(int i=0;i<482;i++)input[i]=(int16_t)(trial%8==0?0:trial%8==1?INT16_MAX:trial%8==2?INT16_MIN:trial%8==3?(i%2?32767:-32768):next());
  int32_t a,b;int sa,sb;silk_sum_sqr_shift(&a,&sa,input+1,n);Energy e={&b,&sb,input+1,n,n};int16_t saved[482];memcpy(saved,input,sizeof(input));
  if(!op_silk_sum_sqr(&e)||a!=b||sa!=sb||memcmp(saved,input,sizeof(input))){printf("PLC energy trial%u n%u %d/%d shift%d/%d\n",trial,n,a,b,sa,sb);return 0;}pl_energy_cases++;
 }return 1;
}
static void pl_to_reference(silk_decoder_state *ref,const Core *core,const ParamState *param,const SideInfoIndices *ind,const silk_PLC_struct *state,int fs,int subfr){
 configure(ref,fs,subfr);ref->sPLC=*state;ref->prev_gain_Q16=core->gain;ref->lagPrev=core->lag;ref->lossCnt=core->loss;ref->prevSignalType=core->signal;
 ref->first_frame_after_reset=param->first;ref->indices=*ind;memcpy(ref->exc_Q14,core->exc,sizeof(core->exc));memcpy(ref->sLPC_Q14_buf,core->lpc,sizeof(core->lpc));memcpy(ref->outBuf,core->out,sizeof(core->out));
}
static int pl_frame(silk_PLC_struct *state,Core *core,const ParamState *param,silk_decoder_control *ctrl,const SideInfoIndices *ind,int16_t *pcm,int fs,int subfr,int lost){
 int n=fs*subfr*5;silk_decoder_state ref;pl_to_reference(&ref,core,param,ind,state,fs,subfr);silk_decoder_control expected=*ctrl;
 int16_t a[322],b[322];a[0]=b[0]=a[321]=b[321]=-12345;memcpy(a+1,pcm,640);memcpy(b+1,pcm,640);
 PlcGuard pg;memset(&pg,0xa5,sizeof(pg));pg.before=0x13579bdf98765432ULL;pg.after=0x2468ace012345678ULL;pg.value=*state;CoreGuard cg;cg.before=pg.before;cg.after=pg.after;cg.value=*core;
 PlcWork work;memset(&work,0xa5,sizeof(work));work.before=pg.before;work.after=pg.after;ParamState prior_param=*param;SideInfoIndices prior_ind=*ind;
 Plc r={&pg.value,&cg.value,param,ctrl,ind,b+1,work.value,fs,subfr,lost,92,2320,48,140,36,n,3552},saved=r;
 silk_PLC(&ref,&expected,a+1,lost);PlcGuard expected_pg=pg;expected_pg.value=ref.sPLC;Core expected_core=*core;expected_core.signal=ref.prevSignalType;expected_core.loss=ref.lossCnt;memcpy(expected_core.lpc,ref.sLPC_Q14_buf,sizeof(core->lpc));
 if(!op_silk_plc(&r)||memcmp(a,b,sizeof(a))||memcmp(&expected_pg,&pg,sizeof(pg))||memcmp(&expected_core,&cg.value,sizeof(Core))||memcmp(&expected,ctrl,sizeof(expected))||memcmp(param,&prior_param,sizeof(*param))||memcmp(ind,&prior_ind,sizeof(*ind))||memcmp(&r,&saved,sizeof(r))||pg.before!=0x13579bdf98765432ULL||pg.after!=0x2468ace012345678ULL||cg.before!=pg.before||cg.after!=pg.after||work.before!=pg.before||work.after!=pg.after){
  printf("PLC frame%u fs%d subfr%d lost%d loss%d first%d signal%d oldfs%d\n",pl_frames,fs,subfr,lost,core->loss,param->first,core->signal,state->fs_kHz);
  for(int i=0;i<n;i++)if(a[i+1]!=b[i+1]){printf("PCM%d %d/%d\n",i,a[i+1],b[i+1]);break;}
  const unsigned char *x=(const unsigned char *)&ref.sPLC,*y=(const unsigned char *)&pg.value;for(unsigned i=0;i<92;i++)if(x[i]!=y[i]){printf("PLC state byte%u %u/%u\n",i,x[i],y[i]);break;}
  for(int i=0;i<16;i++)if(expected_core.lpc[i]!=cg.value.lpc[i]){printf("LPC%d %d/%d\n",i,expected_core.lpc[i],cg.value.lpc[i]);break;}return 0;
 }
 if(state->fs_kHz!=fs)pl_resets++;if(lost){pl_losses++;pl_samples+=n;}else pl_updates++;pl_frames++;pl_history+=33+820;
 *state=pg.value;*core=cg.value;memcpy(pcm,b+1,640);return 1;
}
static int pl_glue(silk_PLC_struct *state,int16_t *pcm,int n,int loss){
 silk_decoder_state ref;configure(&ref,16,4);ref.sPLC=*state;ref.lossCnt=loss;int16_t a[322],b[322];a[0]=b[0]=a[321]=b[321]=-12345;memcpy(a+1,pcm,640);memcpy(b+1,pcm,640);
 PlcGuard pg;memset(&pg,0xa5,sizeof(pg));pg.before=0x13579bdf98765432ULL;pg.after=0x2468ace012345678ULL;pg.value=*state;Glue r={&pg.value,b+1,n,loss,92,n},saved=r;
 silk_PLC_glue_frames(&ref,a+1,n);PlcGuard expected_pg=pg;expected_pg.value=ref.sPLC;
 if(!op_silk_plc_glue(&r)||memcmp(a,b,sizeof(a))||memcmp(&expected_pg,&pg,sizeof(pg))||memcmp(&r,&saved,sizeof(r))||pg.before!=0x13579bdf98765432ULL||pg.after!=0x2468ace012345678ULL){printf("PLC glue%u n%d loss%d energy%d shift%d\n",pl_glues,n,loss,state->conc_energy,state->conc_energy_shift);return 0;}
 if(memcmp(a+1,pcm,n*2))pl_fades++;pl_glues++;pl_samples+=n;*state=pg.value;memcpy(pcm,b+1,640);return 1;
}
static int pl_glue_tests(void){
 for(unsigned trial=0;trial<8192;trial++){
  silk_PLC_struct state;memset(&state,0xa5,92);state.last_frame_lost=0;int16_t pcm[320];int n=1+next()%320;
  for(int frame=0;frame<4;frame++){
   for(int i=0;i<320;i++)pcm[i]=(int16_t)(trial%6==0?0:trial%6==1?INT16_MIN:trial%6==2?INT16_MAX:frame<2?(int)(next()%5)-2:next());
   if(!pl_glue(&state,pcm,n,frame<2?1:0))return 0;
  }
 }return 1;
}
static int pl_sequences(void){
 const int rates[]={8,12,16};
 for(int rate=0;rate<3;rate++)for(int subfr=2;subfr<=4;subfr+=2)for(unsigned trial=0;trial<256;trial++){
  int fs=rates[rate],order=fs==16?16:10,n=fs*subfr*5;Core core;ParamState param;silk_decoder_control ctrl;init(&core,&param,&ctrl,fs,trial);core.loss=0;param.first=1;
  for(int i=0;i<320;i++)core.exc[i]=(int32_t)next();silk_PLC_struct state;memset(&state,0xa5,92);state.fs_kHz=0;state.prevLTP_scale_Q14=8192;state.last_frame_lost=0;state.conc_energy=0;state.conc_energy_shift=0;
  silk_CNG_struct noise;memset(&noise,0,sizeof(noise));silk_resampler_state_struct ra,rb;silk_resampler_init(&ra,fs*1000,48000,0);ResampleInit ri={&rb,fs*1000,48000,304};if(!op_silk_resampler_init(&ri))return 0;
  SideInfoIndices ind;memset(&ind,0,sizeof(ind));
  for(int frame=0;frame<12;frame++){
   int lost=frame%6>=3||(frame==0&&trial%4==0);int16_t pcm[320];for(int i=0;i<320;i++)pcm[i]=-12345;
   param.loss=core.loss;
   if(!lost){
    int cond=(trial+frame)%3;ind.signalType=(int8_t)((trial+frame/6)%3);ind.quantOffsetType=(int8_t)((trial+frame)%2);ind.Seed=(int8_t)((trial+frame)%4);ind.NLSFInterpCoef_Q2=(int8_t)((trial+frame)%5);
    ind.NLSFIndices[0]=(int8_t)(next()%32);for(int i=1;i<=order;i++)ind.NLSFIndices[i]=(int8_t)((int)(next()%7)-3);
    for(int i=0;i<subfr;i++)ind.GainsIndices[i]=(int8_t)(next()%(i==0&&cond!=2?64:41));ind.PERIndex=(int8_t)(next()%3);ind.LTP_scaleIndex=(int8_t)(next()%3);ind.lagIndex=(int16_t)(next()%(fs*16+1));ind.contourIndex=(int8_t)(next()%(fs==8?(subfr==2?3:11):(subfr==2?12:34)));
    for(int i=0;i<subfr;i++)ind.LTPIndex[i]=(int8_t)(next()%(8<<ind.PERIndex));if(!parameters(&ind,&param,&ctrl,fs,subfr,cond))continue;
    int pulses[320];for(int i=0;i<320;i++)pulses[i]=i<n?(trial%8==0?32767:trial%8==1?-32768:(int)(next()%33)-16):0;
    if(!core_frame(&core,&ctrl,&ind,pulses,fs,subfr))return 0;memcpy(pcm,core.out+fs*20-n,n*2);
   }
   if(!pl_frame(&state,&core,&param,&ctrl,&ind,pcm,fs,subfr,lost))return 0;
   if(lost){int mem=fs*20;memmove(core.out,core.out+n,(mem-n)*2);memcpy(core.out+mem-n,pcm,n*2);}else{core.loss=0;param.first=0;}
   if(!pl_glue(&state,pcm,n,core.loss)||!cn_frame(&noise,&core,&param,&ctrl,pcm,fs,subfr,n))return 0;
   core.lag=ctrl.pitchL[subfr-1];int16_t x[960],y[960];unsigned char work[736];int count=subfr*5*48;for(int i=0;i<960;i++)x[i]=y[i]=-12345;
   Resample rr={&rb,y,pcm,work,n,n,count,304,736};if(silk_resampler(&ra,x,pcm,n)||op_silk_resampler(&rr)!=count||memcmp(x,y,sizeof(x))){puts("PLC/CNG connected resampling mismatch");return 0;}pl_connected++;pl_resampled+=count;
  }
 }return 1;
}
static int pl_adversarial(void){
 const int rates[]={8,12,16};
 for(unsigned trial=0;trial<2048;trial++){
  int fs=rates[trial%3],subfr=trial%2?2:4;Core core;ParamState param;silk_decoder_control ctrl;init(&core,&param,&ctrl,fs,trial);core.loss=0;param.first=trial%4==0;core.signal=trial%3;
  for(int i=0;i<320;i++)core.exc[i]=(int32_t)next();silk_PLC_struct state;memset(&state,0xa5,92);state.fs_kHz=0;state.last_frame_lost=0;state.conc_energy=0;state.conc_energy_shift=0;state.prevLTP_scale_Q14=8192;
  SideInfoIndices ind;memset(&ind,0,sizeof(ind));
  for(int frame=0;frame<12;frame++){
   if(frame%3==0){fs=rates[(trial+frame/3)%3];subfr=(trial+frame/3)%2?2:4;}
   int order=fs==16?16:10,n=fs*subfr*5,lost=frame%3!=0;ind.signalType=(int8_t)((trial+frame)%3);
   for(int i=0;i<4;i++){ctrl.pitchL[i]=fs*2+next()%(fs*16+1);ctrl.Gains_Q16[i]=trial%4==0?1:trial%4==1?INT32_MAX:trial%4==2?65536:1+(next()&0x3fffffff);}
   for(int i=0;i<32;i++)ctrl.PredCoef_Q12[i/16][i%16]=(int16_t)(trial%8==0?0:trial%8==1?32767:trial%8==2?-32768:next());
   for(int i=0;i<20;i++)ctrl.LTPCoef_Q14[i]=(int16_t)(trial%9==0?0:trial%9==1?-32768:trial%9==2?32767:trial%9==3?100:trial%9==4?3000:next());
   ctrl.LTP_scale_Q14=(int)(next()%16385);int16_t pcm[320];for(int i=0;i<320;i++)pcm[i]=(int16_t)next();
   if(!pl_frame(&state,&core,&param,&ctrl,&ind,pcm,fs,subfr,lost))return 0;
   if(!lost){core.loss=0;param.first=trial%4==0;}
   int mem=fs*20;memmove(core.out,core.out+n,(mem-n)*2);memcpy(core.out+mem-n,pcm,n*2);
   if(!pl_glue(&state,pcm,n,core.loss))return 0;core.lag=ctrl.pitchL[subfr-1];
  }
 }return 1;
}
static int pl_invalid(void){
 Core core;ParamState param;silk_decoder_control ctrl;init(&core,&param,&ctrl,16,0);core.loss=0;core.signal=2;param.first=0;SideInfoIndices ind;memset(&ind,0,sizeof(ind));ind.signalType=2;
 silk_PLC_struct state;memset(&state,0,92);state.fs_kHz=16;state.pitchL_Q8=100*256;state.nb_subfr=4;state.subfr_length=80;state.prevGain_Q16[0]=state.prevGain_Q16[1]=65536;state.prevLTP_scale_Q14=8192;
 for(int i=0;i<4;i++){ctrl.pitchL[i]=100;ctrl.Gains_Q16[i]=65536;}ctrl.LTP_scale_Q14=8192;
 int16_t pcm[320];unsigned char work[3552];memset(pcm,0xa5,sizeof(pcm));memset(work,0xa5,sizeof(work));Plc base={&state,&core,&param,&ctrl,&ind,pcm,work,16,4,0,92,2320,48,140,36,320,3552};
 for(unsigned k=0;k<42;k++){
  Plc r=base;Core original_core=core;ParamState original_param=param;silk_decoder_control original_ctrl=ctrl;SideInfoIndices original_ind=ind;silk_PLC_struct original_state=state;
  switch(k){case 0:r.state=NULL;break;case 1:r.core=NULL;break;case 2:r.param=NULL;break;case 3:r.ctrl=NULL;break;case 4:r.ind=NULL;break;case 5:r.pcm=NULL;break;case 6:r.work=NULL;break;case 7:r.fs=24;break;case 8:r.subfr=3;break;case 9:r.lost=2;break;case 10:r.state_cap=91;break;case 11:r.core_cap=2319;break;case 12:r.param_cap=47;break;case 13:r.ctrl_cap=139;break;case 14:r.ind_cap=35;break;case 15:r.pcm_cap=319;break;case 16:r.work_cap=3551;break;case 17:core.loss=-1;break;case 18:r.lost=1;core.loss=INT32_MAX;break;case 19:ind.signalType=3;break;case 20:ctrl.Gains_Q16[2]=0;break;case 21:ctrl.Gains_Q16[3]=-1;break;case 22:ctrl.LTP_scale_Q14=-1;break;case 23:ctrl.LTP_scale_Q14=16385;break;case 24:ctrl.pitchL[0]=31;break;case 25:ctrl.pitchL[3]=289;break;case 26:r.lost=1;state.prevGain_Q16[0]=0;break;case 27:r.lost=1;state.prevGain_Q16[1]=-1;break;case 28:r.lost=1;state.subfr_length=0;break;case 29:r.lost=1;state.subfr_length=81;break;case 30:r.lost=1;state.nb_subfr=3;break;case 31:r.lost=1;state.pitchL_Q8=0;break;case 32:r.lost=1;state.pitchL_Q8=31*256;break;case 33:r.lost=1;state.pitchL_Q8=289*256;break;case 34:r.lost=1;param.first=2;break;case 35:r.lost=1;core.signal=3;break;case 36:r.lost=1;state.prevLTP_scale_Q14=-1;break;case 37:r.lost=1;state.prevLTP_scale_Q14=16385;break;case 38:r.lost=-1;break;case 39:r.fs=0;break;case 40:r.lost=1;param.first=-1;break;case 41:r.lost=1;core.signal=-1;break;}
  Plc saved=r;Core prior_core=core;ParamState prior_param=param;silk_decoder_control prior_ctrl=ctrl;SideInfoIndices prior_ind=ind;silk_PLC_struct prior_state=state;int16_t prior_pcm[320];unsigned char prior_work[3552];memcpy(prior_pcm,pcm,sizeof(pcm));memcpy(prior_work,work,sizeof(work));
  if(op_silk_plc(&r)||memcmp(&r,&saved,sizeof(r))||memcmp(&core,&prior_core,sizeof(core))||memcmp(&param,&prior_param,sizeof(param))||memcmp(&ctrl,&prior_ctrl,sizeof(ctrl))||memcmp(&ind,&prior_ind,sizeof(ind))||memcmp(&state,&prior_state,92)||memcmp(pcm,prior_pcm,sizeof(pcm))||memcmp(work,prior_work,sizeof(work))){printf("PLC guard%u\n",k);return 0;}
  core=original_core;param=original_param;ctrl=original_ctrl;ind=original_ind;state=original_state;pl_guards++;
 }
 Glue gb={&state,pcm,320,0,92,320};state.last_frame_lost=1;
 for(unsigned k=0;k<12;k++){
  Glue r=gb;silk_PLC_struct original=state;switch(k){case 0:r.state=NULL;break;case 1:r.pcm=NULL;break;case 2:r.n=0;break;case 3:r.n=321;break;case 4:r.n=-1;break;case 5:r.loss=-1;break;case 6:r.state_cap=91;break;case 7:r.pcm_cap=319;break;case 8:state.last_frame_lost=2;break;case 9:state.conc_energy=-1;break;case 10:state.conc_energy_shift=-1;break;case 11:state.conc_energy_shift=32;break;}
  Glue saved=r;silk_PLC_struct prior=state;int16_t prior_pcm[320];memcpy(prior_pcm,pcm,sizeof(pcm));if(op_silk_plc_glue(&r)||memcmp(&r,&saved,sizeof(r))||memcmp(&state,&prior,92)||memcmp(pcm,prior_pcm,sizeof(pcm))){printf("PLC glue guard%u\n",k);return 0;}state=original;pl_guards++;
 }
 int32_t energy=123456,shift=654321;Energy eb={&energy,&shift,pcm,320,320};
 for(unsigned k=0;k<6;k++){
  Energy r=eb;switch(k){case 0:r.energy=NULL;break;case 1:r.shift=NULL;break;case 2:r.in=NULL;break;case 3:r.n=481;break;case 4:r.n=UINT32_MAX;break;case 5:r.in_cap=319;break;}
  Energy saved=r;int16_t prior_pcm[320];memcpy(prior_pcm,pcm,sizeof(pcm));if(op_silk_sum_sqr(&r)||memcmp(&r,&saved,sizeof(r))||energy!=123456||shift!=654321||memcmp(pcm,prior_pcm,sizeof(pcm))){printf("PLC energy guard%u\n",k);return 0;}pl_guards++;
 }
 if(op_silk_plc(NULL)||op_silk_plc_glue(NULL)||op_silk_sum_sqr(NULL))return 0;pl_guards+=3;return 1;
}
int main(void){
 if(!pl_energy_tests()||!pl_glue_tests()||!pl_sequences()||!pl_adversarial()||!pl_invalid())return 1;
 printf("SILK PLC: %u energy vectors, %u exact state/PCM frames (%u updates, %u concealed, %u rate resets), %u glue frames (%u faded), %u connected core/PLC/glue/CNG/resampling, %llu int16 PCM comparisons, %llu history values, %llu connected resampled samples, %u guards\n",pl_energy_cases,pl_frames,pl_updates,pl_losses,pl_resets,pl_glues,pl_fades,pl_connected,pl_samples,pl_history,pl_resampled,pl_guards);return 0;
}
