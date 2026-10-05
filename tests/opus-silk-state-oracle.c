/* Test-only complete SILK parameter stage and atomic failure checks. */
#include "lamp-test.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "main.h"
#include "tables.h"
typedef struct {int8_t gain;unsigned char padding[3];int16_t prev[16];int first,loss;uint32_t reserved;} ParamState;
typedef struct {SideInfoIndices *ind;ParamState *state;silk_decoder_control *out;int fs,subfr,cond;unsigned ind_cap,state_cap,out_cap;} Parameters;
typedef struct {int lag,signal;} Previous;
typedef struct {ec_dec *ec;Previous *state;SideInfoIndices *out;int fs,subfr,vad,lbrr,cond;unsigned out_cap,state_cap;} Indices;
LAMP_ABI int op_silk_decode_parameters(Parameters *);
LAMP_ABI int op_silk_indices(Indices *);
typedef char state_size[(sizeof(ParamState)==48)?1:-1];
typedef char control_size[(sizeof(silk_decoder_control)==140)?1:-1];
typedef char request_size[(sizeof(Parameters)==48)?1:-1];
static uint32_t rng=0x9c4a192d;
static uint32_t next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static unsigned frames,connected_frames,voiced,interpolated,resets,losses,late_rejections,guards;
static unsigned long long coefficients;
typedef struct {uint64_t before;ParamState value;uint64_t after;} StateGuard;
typedef struct {uint64_t before;SideInfoIndices value;uint64_t after;} IndexGuard;
typedef struct {uint64_t before;silk_decoder_control value;uint64_t after;} ControlGuard;
static void configure(silk_decoder_state *state,int fs,int subfr){
 memset(state,0,sizeof(*state));state->fs_kHz=fs;state->nb_subfr=subfr;state->LPC_order=fs==16?16:10;
 state->psNLSF_CB=fs==16?&silk_NLSF_CB_WB:&silk_NLSF_CB_NB_MB;
 state->pitch_lag_low_bits_iCDF=fs==8?silk_uniform4_iCDF:fs==12?silk_uniform6_iCDF:silk_uniform8_iCDF;
 state->pitch_contour_iCDF=fs==8?(subfr==2?silk_pitch_contour_10_ms_NB_iCDF:silk_pitch_contour_NB_iCDF):(subfr==2?silk_pitch_contour_10_ms_iCDF:silk_pitch_contour_iCDF);
}
static int valid_vector(const int16_t *x,const silk_NLSF_CB_struct *cb){
 int previous=0;for(int i=0;i<cb->order;i++){if(x[i]-previous<cb->deltaMin_Q15[i])return 0;previous=x[i];}
 return 32768-previous>=cb->deltaMin_Q15[cb->order];
}
static int check(const SideInfoIndices *indices,ParamState *history,silk_decoder_control *control,int fs,int subfr,int cond){
 IndexGuard ig;StateGuard sg;ControlGuard cg;memset(&ig,0xa5,sizeof(ig));memset(&sg,0xa5,sizeof(sg));memset(&cg,0xa5,sizeof(cg));
 ig.before=sg.before=cg.before=0x13579bdf98765432ULL;ig.after=sg.after=cg.after=0x2468ace012345678ULL;
 ig.value=*indices;sg.value=*history;cg.value=*control;IndexGuard old_ig=ig;StateGuard old_sg=sg;ControlGuard old_cg=cg;
 Parameters request={&ig.value,&sg.value,&cg.value,fs,subfr,cond,36,48,140},saved=request;
 silk_decoder_state reference;configure(&reference,fs,subfr);reference.indices=*indices;reference.LastGainIndex=history->gain;
 memcpy(reference.prevNLSF_Q15,history->prev,sizeof(history->prev));reference.first_frame_after_reset=history->first;reference.lossCnt=history->loss;
 int16_t nlsf[16];silk_NLSF_decode(nlsf,indices->NLSFIndices,reference.psNLSF_CB);
 int valid=valid_vector(nlsf,reference.psNLSF_CB),actual=op_silk_decode_parameters(&request);
 if(!valid){
  if(actual||memcmp(&ig,&old_ig,sizeof(ig))||memcmp(&sg,&old_sg,sizeof(sg))||memcmp(&cg,&old_cg,sizeof(cg))||memcmp(&request,&saved,sizeof(request))){puts("Late failure not atomic");return 0;}
  late_rejections++;return 1;
 }
 silk_decoder_control expected=*control;silk_decode_parameters(&reference,&expected,cond);
 ParamState expected_history=*history;expected_history.gain=reference.LastGainIndex;memcpy(expected_history.prev,reference.prevNLSF_Q15,sizeof(history->prev));
 if(!actual||memcmp(&request,&saved,sizeof(request))||memcmp(&ig.value,&reference.indices,sizeof(ig.value))||memcmp(&sg.value,&expected_history,sizeof(sg.value))||memcmp(&cg.value,&expected,sizeof(expected))||ig.before!=old_ig.before||ig.after!=old_ig.after||sg.before!=old_sg.before||sg.after!=old_sg.after||cg.before!=old_cg.before||cg.after!=old_cg.after){
  printf("Parameter mismatch frame=%u fs=%d subfr=%d cond=%d interp=%d first=%d loss=%d\n",frames,fs,subfr,cond,indices->NLSFInterpCoef_Q2,history->first,history->loss);
  const unsigned char *a=(const unsigned char *)&expected,*b=(const unsigned char *)&cg.value;for(int i=0;i<140;i++)if(a[i]!=b[i])printf("Control byte%d %u/%u\n",i,a[i],b[i]);return 0;
 }
 if(indices->signalType==2)voiced++;if(history->first)resets++;else if(indices->NLSFInterpCoef_Q2<4)interpolated++;if(history->loss)losses++;
 *history=sg.value;*control=cg.value;frames++;coefficients+=subfr*7+reference.LPC_order*3+1;return 1;
}
static void initialize(ParamState *history,silk_decoder_control *control,int order){
 memset(history,0xa5,sizeof(*history));memset(control,0xa5,sizeof(*control));history->gain=(int8_t)(next()%64);history->first=0;history->loss=0;
 for(int i=0;i<order;i++)history->prev[i]=(int16_t)((i+1)*32768/(order+1));
}
static int standalone(void){
 const int rates[]={8,12,16};
 for(int r=0;r<3;r++)for(int subfr=2;subfr<=4;subfr+=2)for(unsigned trial=0;trial<4096;trial++){
  int fs=rates[r],order=fs==16?16:10;ParamState history;silk_decoder_control control;initialize(&history,&control,order);
  for(int frame=0;frame<4;frame++){
   SideInfoIndices indices;memset(&indices,0xa5,sizeof(indices));int cond=(trial+frame)%3;
   indices.signalType=(int8_t)((trial+frame)%3);indices.NLSFInterpCoef_Q2=(int8_t)((trial/3+frame)%5);
   indices.NLSFIndices[0]=(int8_t)(next()%32);
   for(int i=1;i<=order;i++)indices.NLSFIndices[i]=(int8_t)(trial%8==0?-10:trial%8==1?10:trial%8==2?0:(int)(next()%21)-10);
   for(int i=0;i<subfr;i++)indices.GainsIndices[i]=(int8_t)(next()%(i==0&&cond!=2?64:41));
   indices.PERIndex=(int8_t)(next()%3);indices.LTP_scaleIndex=(int8_t)(next()%3);indices.lagIndex=(int16_t)next();
   indices.contourIndex=(int8_t)(next()%(fs==8?(subfr==2?3:11):(subfr==2?12:34)));
   for(int i=0;i<subfr;i++)indices.LTPIndex[i]=(int8_t)(next()%(8<<indices.PERIndex));
   history.first=(trial+frame)%7==0;history.loss=(trial+frame)%4==0?(int)(next()%100+1):0;
   if(!check(&indices,&history,&control,fs,subfr,cond))return 0;
  }
 }
 return 1;
}
static int connected(void){
 const int rates[]={8,12,16};unsigned char payload[1275];
 for(unsigned trial=0;trial<8192;trial++){
  int fs=rates[trial%3],subfr=trial%2?2:4,order=fs==16?16:10;
  ParamState history;silk_decoder_control control;initialize(&history,&control,order);
  silk_decoder_state reference;configure(&reference,fs,subfr);reference.ec_prevSignalType=2;reference.ec_prevLagIndex=100;
  Previous previous={100,2};SideInfoIndices indices;memset(&indices,0xa5,sizeof(indices));reference.indices=indices;
  for(int frame=0;frame<4;frame++){
   unsigned len=trial%8==0?0:trial%8==1?1:trial%8==2?1275:next()%1276;for(unsigned i=0;i<len;i++)payload[i]=(unsigned char)next();
   ec_dec ea,eb;memset(&ea,0,sizeof(ea));ec_dec_init(&ea,payload,len);eb=ea;
   if(trial%3==0){ec_dec_bit_logp(&ea,3);ec_dec_bit_logp(&eb,3);}
   int vad=(trial+frame)%2,lbrr=(trial/2+frame)%2,cond=(trial+frame)%3;reference.VAD_flags[frame%3]=vad;
   silk_decode_indices(&reference,&ea,frame%3,lbrr,cond);
   Indices request={&eb,&previous,&indices,fs,subfr,vad,lbrr,cond,36,8};
   if(!op_silk_indices(&request)||memcmp(&indices,&reference.indices,sizeof(indices))||memcmp(&ea,&eb,sizeof(ea)))return 0;
   history.first=frame==0;history.loss=(trial+frame)%4==0?1:0;
   if(!check(&indices,&history,&control,fs,subfr,cond))return 0;connected_frames++;
  }
 }
 return 1;
}
static int invalid(void){
 ParamState history;silk_decoder_control control;SideInfoIndices indices;initialize(&history,&control,16);memset(&indices,0,sizeof(indices));
 Parameters base={&indices,&history,&control,16,4,0,36,48,140};
 for(unsigned k=0;k<30;k++){
  Parameters r=base;ParamState prior_history=history;SideInfoIndices prior_indices=indices;silk_decoder_control prior_control=control;
  switch(k){case 0:r.ind=NULL;break;case 1:r.state=NULL;break;case 2:r.out=NULL;break;case 3:r.fs=24;break;case 4:r.subfr=3;break;case 5:r.cond=3;break;case 6:r.ind_cap=35;break;case 7:r.state_cap=47;break;case 8:r.out_cap=139;break;case 9:history.gain=-1;break;case 10:history.first=2;break;case 11:history.loss=-1;break;case 12:history.prev[15]=-1;break;case 13:indices.NLSFInterpCoef_Q2=5;break;case 14:indices.GainsIndices[0]=64;break;case 15:indices.GainsIndices[3]=41;break;case 16:indices.NLSFIndices[0]=32;break;case 17:indices.NLSFIndices[16]=11;break;case 18:indices.signalType=3;break;case 19:indices.signalType=2;indices.PERIndex=3;break;case 20:indices.signalType=2;indices.LTP_scaleIndex=3;break;case 21:indices.signalType=2;indices.LTPIndex[3]=8;break;case 22:indices.signalType=2;indices.contourIndex=34;break;case 23:r.cond=-1;break;case 24:history.first=-1;break;case 25:indices.NLSFIndices[1]=-11;break;case 26:r.subfr=0;break;case 27:r.fs=0;break;case 28:history.gain=64;break;case 29:indices.signalType=2;indices.contourIndex=-1;break;}
  Parameters saved=r;ParamState changed_history=history;SideInfoIndices changed_indices=indices;
  if(op_silk_decode_parameters(&r)||memcmp(&r,&saved,sizeof(r))||memcmp(&history,&changed_history,sizeof(history))||memcmp(&indices,&changed_indices,sizeof(indices))||memcmp(&control,&prior_control,sizeof(control))){printf("Guard failure %u\n",k);return 0;}
  history=prior_history;indices=prior_indices;guards++;
 }
 if(op_silk_decode_parameters(NULL))return 0;guards++;return 1;
}
int main(void){
 if(!standalone()||!connected()||!invalid())return 1;
 printf("SILK state: %u exact parameter/history frames (%u connected side-information, %u voiced, %u interpolated, %u reset, %u after loss), %u atomic invalid-NLSF rejections, %llu integer coefficients, %u guards\n",frames,connected_frames,voiced,interpolated,resets,losses,late_rejections,coefficients,guards);
 return 0;
}
