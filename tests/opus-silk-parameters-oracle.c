/* Test-only normative gain/pitch/LTP parameter reconstruction. */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "main.h"
#include "silk-pitch-ltp-reference.inc"
typedef struct {const opus_int8 *ind;opus_int32 *out;opus_int8 *prev;int subfr,conditional;unsigned ind_cap,out_cap,prev_cap;} Gains;
typedef struct {const SideInfoIndices *ind;int *pitch;opus_int16 *ltp;int *scale;int fs,subfr;unsigned pitch_cap,ltp_cap,scale_cap;} PitchLtp;
typedef struct {int lag,signal;} Previous;
typedef struct {ec_dec *ec;Previous *state;SideInfoIndices *out;int fs,subfr,vad,lbrr,cond;unsigned out_cap,state_cap;} Indices;
int op_silk_log2lin(int);
int op_silk_gains(Gains *);
int op_silk_pitch_ltp(PitchLtp *);
int op_silk_indices(Indices *);
static uint32_t rng=0x91a587bc;
static uint32_t next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static unsigned log_checks,gain_checks,pitch_checks,connected_checks,guards;
static unsigned long long parameters;
static int gains(const opus_int8 *indices,opus_int8 *prev,int conditional,int subfr){
 opus_int8 before=*prev,expected_prev=*prev,saved_indices[4];memcpy(saved_indices,indices,4);
 int a[6],b[6];for(int i=0;i<6;i++)a[i]=b[i]=0x13579bdf;
 struct {unsigned char before;opus_int8 value;unsigned char after;} state={0xd3,*prev,0x71};
 silk_gains_dequant(a+1,indices,&expected_prev,conditional,subfr);
 Gains request={indices,b+1,&state.value,subfr,conditional,subfr,subfr,1},saved=request;
 if(!op_silk_gains(&request)||memcmp(&request,&saved,sizeof(request))||memcmp(a,b,sizeof(a))||state.value!=expected_prev||state.before!=0xd3||state.after!=0x71||memcmp(indices,saved_indices,4)||b[0]!=0x13579bdf||b[subfr+1]!=0x13579bdf){printf("Gain mismatch prev=%d cond=%d subfr=%d gains=%d,%d,%d,%d\n",before,conditional,subfr,indices[0],indices[1],indices[2],indices[3]);return 0;}
 *prev=state.value;gain_checks++;parameters+=subfr;return 1;
}
static int pitch_ltp(SideInfoIndices *ind,int fs,int subfr){
 silk_decoder_state state;silk_decoder_control control;memset(&state,0,sizeof(state));memset(&control,0xa5,sizeof(control));
 state.fs_kHz=fs;state.nb_subfr=subfr;state.indices=*ind;
 reference_pitch_ltp(&state,&control);
 int pitch[6],scale[3];opus_int16 ltp[22];
 for(int i=0;i<6;i++)pitch[i]=0x13579bdf;
 for(int i=0;i<3;i++)scale[i]=0x2468ace0;
 for(int i=0;i<22;i++)ltp[i]=-12345;
 SideInfoIndices initial=*ind;
 PitchLtp request={ind,pitch+1,ltp+1,scale+1,fs,subfr,subfr,subfr*5,1},saved=request;
 if(!op_silk_pitch_ltp(&request)||memcmp(&request,&saved,sizeof(request))||memcmp(ind,&initial,sizeof(initial))||memcmp(pitch+1,control.pitchL,subfr*4)||memcmp(ltp+1,control.LTPCoef_Q14,subfr*5*2)||scale[1]!=control.LTP_scale_Q14||pitch[0]!=0x13579bdf||pitch[subfr+1]!=0x13579bdf||ltp[0]!=-12345||ltp[subfr*5+1]!=-12345||scale[0]!=0x2468ace0||scale[2]!=0x2468ace0){printf("Pitch/LTP mismatch fs=%d subfr=%d signal=%d lag=%d contour=%d per=%d scale=%d\n",fs,subfr,ind->signalType,ind->lagIndex,ind->contourIndex,ind->PERIndex,ind->LTP_scaleIndex);return 0;}
 for(int i=subfr+1;i<6;i++)if(pitch[i]!=0x13579bdf)return 0;
 for(int i=subfr*5+1;i<22;i++)if(ltp[i]!=-12345)return 0;
 pitch_checks++;parameters+=subfr*6+1;return 1;
}
static int standalone(void){
 for(int x=-128;x<=3967;x++){if(op_silk_log2lin(x)!=silk_log2lin(x)){printf("Log-to-linear mismatch %d\n",x);return 0;}log_checks++;}
 if(op_silk_log2lin(3968)||op_silk_log2lin(0x7fffffff))return 0;guards+=2;
 for(int subfr=2;subfr<=4;subfr+=2)for(int previous=0;previous<64;previous++)for(int cond=0;cond<2;cond++)for(int first=0;first<(cond?41:64);first++)for(int delta=0;delta<41;delta++){
  opus_int8 ind[4]={(opus_int8)first,(opus_int8)delta,(opus_int8)(next()%41),(opus_int8)(next()%41)},state=(opus_int8)previous;
  if(!gains(ind,&state,cond,subfr))return 0;
 }
 const int rates[3]={8,12,16};
 for(int rate=0;rate<3;rate++)for(int subfr=2;subfr<=4;subfr+=2){
  int fs=rates[rate],contours=fs==8?(subfr==2?3:11):(subfr==2?12:34);
  for(int contour=0;contour<contours;contour++)for(int lag=-16;lag<fs*16+16;lag++)for(int per=0;per<3;per++)for(int scale=0;scale<3;scale++){
   SideInfoIndices ind;memset(&ind,0xa5,sizeof(ind));ind.signalType=2;ind.contourIndex=(opus_int8)contour;ind.lagIndex=(opus_int16)lag;ind.PERIndex=(opus_int8)per;ind.LTP_scaleIndex=(opus_int8)scale;
   for(int i=0;i<subfr;i++)ind.LTPIndex[i]=(opus_int8)(next()%(8<<per));
   if(!pitch_ltp(&ind,fs,subfr))return 0;
  }
  for(int signal=0;signal<3;signal++)for(int lag=-32768;lag<=32767;lag+=65535){
   SideInfoIndices ind;memset(&ind,0xa5,sizeof(ind));ind.signalType=(opus_int8)signal;ind.lagIndex=(opus_int16)lag;
   if(signal==2){ind.contourIndex=0;ind.PERIndex=0;ind.LTP_scaleIndex=0;memset(ind.LTPIndex,0,4);}
   if(!pitch_ltp(&ind,fs,subfr))return 0;
  }
 }
 return 1;
}
static int connected(void){
 unsigned char payload[1275];const int rates[3]={8,12,16};
 for(unsigned k=0;k<8192;k++){
  unsigned len=k%8==0?0:k%8==1?1:k%8==2?1275:next()%1276;
  for(unsigned i=0;i<len;i++)payload[i]=k%16==0?0:k%16==1?255:(unsigned char)next();
  int fs=rates[k%3],subfr=k%2?2:4;
  Previous previous={100,2};opus_int8 last_gain=(opus_int8)(next()%64);
  SideInfoIndices ind;memset(&ind,0xa5,sizeof(ind));
  silk_decoder_state state;memset(&state,0,sizeof(state));state.fs_kHz=fs;state.nb_subfr=subfr;state.LPC_order=fs==16?16:10;state.psNLSF_CB=fs==16?&silk_NLSF_CB_WB:&silk_NLSF_CB_NB_MB;
  state.pitch_lag_low_bits_iCDF=fs==8?silk_uniform4_iCDF:fs==12?silk_uniform6_iCDF:silk_uniform8_iCDF;
  state.pitch_contour_iCDF=fs==8?(subfr==2?silk_pitch_contour_10_ms_NB_iCDF:silk_pitch_contour_NB_iCDF):(subfr==2?silk_pitch_contour_10_ms_iCDF:silk_pitch_contour_iCDF);
  state.ec_prevLagIndex=100;state.ec_prevSignalType=2;state.indices=ind;
  for(int frame=0;frame<4;frame++){
   ec_dec ea,eb;memset(&ea,0,sizeof(ea));ec_dec_init(&ea,payload,len);eb=ea;
   int vad=(k+frame)%2,lbrr=(k/2+frame)%2,cond=(k+frame)%3;
   state.VAD_flags[frame%3]=(opus_int8)vad;
   if(k%3==0){ec_dec_bit_logp(&ea,3);ec_dec_bit_logp(&eb,3);}
   silk_decode_indices(&state,&ea,frame%3,lbrr,cond);
   Indices request={&eb,&previous,&ind,fs,subfr,vad,lbrr,cond,36,8};
   if(!op_silk_indices(&request)||memcmp(&ind,&state.indices,sizeof(ind))||memcmp(&ea,&eb,sizeof(ea)))return 0;
   if(!gains(ind.GainsIndices,&last_gain,cond==2,subfr)||!pitch_ltp(&ind,fs,subfr))return 0;
   connected_checks++;
  }
 }
 return 1;
}
static int invalid(void){
 opus_int8 indices[4]={0},previous=10;int gains_out[4],pitch[4],scale[1];opus_int16 ltp[20];
 for(int i=0;i<4;i++)gains_out[i]=pitch[i]=0x13579bdf;
 for(int i=0;i<20;i++)ltp[i]=-12345;scale[0]=0x2468ace0;
 Gains good={indices,gains_out,&previous,4,0,4,4,1};
 for(unsigned k=0;k<16;k++){
  Gains r=good;opus_int8 initial_previous=previous;
  switch(k){case 0:r.ind=NULL;break;case 1:r.out=NULL;break;case 2:r.prev=NULL;break;case 3:r.subfr=0;break;case 4:r.subfr=3;break;
   case 5:r.conditional=2;break;case 6:r.ind_cap=3;break;case 7:r.out_cap=3;break;case 8:r.prev_cap=0;break;case 9:previous=64;break;case 10:previous=-1;break;
   case 11:indices[0]=64;break;case 12:indices[3]=41;break;case 13:indices[0]=-1;break;case 14:indices[0]=41;r.conditional=1;break;case 15:r.conditional=-1;break;}
  Gains saved=r;opus_int8 saved_previous=previous;
  if(op_silk_gains(&r)||memcmp(&r,&saved,sizeof(r))||previous!=saved_previous)return 0;
  for(int i=0;i<4;i++)if(gains_out[i]!=0x13579bdf)return 0;
  previous=initial_previous;memset(indices,0,4);guards++;
 }
 SideInfoIndices ind;memset(&ind,0,sizeof(ind));ind.signalType=2;
 PitchLtp pg={&ind,pitch,ltp,scale,16,4,4,20,1};
 for(unsigned k=0;k<17;k++){
  PitchLtp r=pg;
  switch(k){case 0:r.ind=NULL;break;case 1:r.pitch=NULL;break;case 2:r.ltp=NULL;break;case 3:r.scale=NULL;break;
   case 4:r.fs=48;break;case 5:r.subfr=3;break;case 6:r.pitch_cap=3;break;case 7:r.ltp_cap=19;break;case 8:r.scale_cap=0;break;
   case 9:ind.signalType=3;break;case 10:ind.contourIndex=34;break;case 11:ind.PERIndex=3;break;case 12:ind.LTP_scaleIndex=3;break;case 13:ind.LTPIndex[3]=8;break;
   case 14:ind.LTPIndex[0]=-1;break;case 15:ind.contourIndex=-1;break;case 16:r.fs=-1;break;}
  PitchLtp saved=r;SideInfoIndices saved_ind=ind;
  if(op_silk_pitch_ltp(&r)||memcmp(&r,&saved,sizeof(r))||memcmp(&ind,&saved_ind,sizeof(ind))||scale[0]!=0x2468ace0)return 0;
  for(int i=0;i<4;i++)if(pitch[i]!=0x13579bdf)return 0;
  for(int i=0;i<20;i++)if(ltp[i]!=-12345)return 0;
  memset(&ind,0,sizeof(ind));ind.signalType=2;guards++;
 }
 if(op_silk_gains(NULL)||op_silk_pitch_ltp(NULL))return 0;guards+=2;return 1;
}
int main(void){
 if(!standalone()||!connected()||!invalid())return 1;
 printf("SILK parameters: %u log-to-linear values, %u gain/state frames, %u pitch/LTP frames, %u connected side-information sequences, %llu integer parameters, %u guards; all exact\n",log_checks,gain_checks,pitch_checks,connected_checks,parameters,guards);
 return 0;
}
