/* Test-only complete normative SILK side-information/pulse comparisons. */
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "main.h"
typedef struct {int lag,signal;} Previous;
typedef struct {ec_dec *ec;Previous *state;SideInfoIndices *out;int fs,subfr,vad,lbrr,cond;unsigned out_cap,state_cap;} Indices;
typedef struct {opus_int16 *ec_ix;unsigned char *pred;int fs,index;unsigned ec_cap,pred_cap;} Unpack;
int op_silk_indices(Indices *);
int op_silk_nlsf_unpack(Unpack *);
int op_silk_pulses(ec_dec *,int *,unsigned,unsigned,unsigned);
typedef char layout_check[(sizeof(SideInfoIndices)==36&&offsetof(SideInfoIndices,lagIndex)==26&&offsetof(SideInfoIndices,Seed)==34&&sizeof(Indices)==56)?1:-1];
static uint32_t rng=0x42f818ac;
static uint32_t next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static unsigned index_checks,pulse_checks,unpack_checks,invalid_checks,voiced_checks,conditional_voiced_checks,primed_checks;
static unsigned long long pulses_compared;
typedef struct {uint32_t before;SideInfoIndices value;uint32_t after;} OutGuard;
typedef struct {uint32_t before;Previous value;uint32_t after;} StateGuard;
static void configure(silk_decoder_state *s,int fs,int subfr){
 s->fs_kHz=fs;s->nb_subfr=subfr;s->LPC_order=fs==16?16:10;
 s->psNLSF_CB=fs==16?&silk_NLSF_CB_WB:&silk_NLSF_CB_NB_MB;
 s->pitch_lag_low_bits_iCDF=fs==8?silk_uniform4_iCDF:fs==12?silk_uniform6_iCDF:silk_uniform8_iCDF;
 s->pitch_contour_iCDF=fs==8?(subfr==2?silk_pitch_contour_10_ms_NB_iCDF:silk_pitch_contour_NB_iCDF):(subfr==2?silk_pitch_contour_10_ms_iCDF:silk_pitch_contour_iCDF);
}
static int trial(const unsigned char *payload,unsigned len,int fs,int subfr,int initial_lag,int initial_signal,int variant,unsigned prime){
 silk_decoder_state reference;memset(&reference,0,sizeof(reference));configure(&reference,fs,subfr);
 StateGuard state={0x13579bdf,{initial_lag,initial_signal},0x2468ace0};
 OutGuard out={0x98765432,{0},0x12345678};
 for(unsigned i=0;i<sizeof(out.value);i++)((unsigned char*)&out.value)[i]=(unsigned char)next();
 reference.indices=out.value;reference.ec_prevLagIndex=initial_lag;reference.ec_prevSignalType=initial_signal;
 for(int frame=0;frame<4;frame++){
  ec_dec ea,eb;memset(&ea,0,sizeof(ea));memset(&eb,0,sizeof(eb));ec_dec_init(&ea,(unsigned char*)payload,len);eb=ea;
  for(unsigned i=0;i<prime;i++){ec_dec_bit_logp(&ea,1+i%12);ec_dec_bit_logp(&eb,1+i%12);if(i%3==0){ec_dec_bits(&ea,1+i%5);ec_dec_bits(&eb,1+i%5);}}
  int vad=(variant+frame)%2,lbrr=((variant+frame)/2)%2,cond=(variant+frame)%3;
  reference.VAD_flags[frame%3]=(opus_int8)vad;
  int was_voiced=reference.ec_prevSignalType==TYPE_VOICED;
  silk_decode_indices(&reference,&ea,frame%3,lbrr,cond);
  Indices request={&eb,&state.value,&out.value,fs,subfr,vad,lbrr,cond,sizeof(SideInfoIndices),sizeof(Previous)},saved=request;
  if(!op_silk_indices(&request)||memcmp(&request,&saved,sizeof(request))||memcmp(&reference.indices,&out.value,sizeof(out.value))||memcmp(&ea,&eb,sizeof(ea))||state.value.lag!=reference.ec_prevLagIndex||state.value.signal!=reference.ec_prevSignalType||state.before!=0x13579bdf||state.after!=0x2468ace0||out.before!=0x98765432||out.after!=0x12345678){
   printf("SILK indices mismatch len=%u fs=%d subfr=%d frame=%d vad=%d lbrr=%d cond=%d prime=%u signal=%d/%d lag=%d/%d\n",len,fs,subfr,frame,vad,lbrr,cond,prime,reference.indices.signalType,out.value.signalType,reference.indices.lagIndex,out.value.lagIndex);
   for(unsigned i=0;i<36;i++)if(((unsigned char*)&reference.indices)[i]!=((unsigned char*)&out.value)[i])printf("byte%u: %u/%u\n",i,((unsigned char*)&reference.indices)[i],((unsigned char*)&out.value)[i]);
   return 0;
  }
  index_checks++;if(prime)primed_checks++;
  if(out.value.signalType==TYPE_VOICED){voiced_checks++;if(was_voiced&&cond==2)conditional_voiced_checks++;}
  int length=fs*5*subfr,padded=(length+15)&~15,pa[322],pb[322];
  for(int i=0;i<322;i++)pa[i]=pb[i]=0x13572468;
  silk_decode_pulses(&ea,pa+1,reference.indices.signalType,reference.indices.quantOffsetType,length);
  if(!op_silk_pulses(&eb,pb+1,out.value.signalType,out.value.quantOffsetType,length)||memcmp(pa,pb,sizeof(pa))||memcmp(&ea,&eb,sizeof(ea))||pb[0]!=0x13572468||pb[padded+1]!=0x13572468){printf("Connected SILK excitation mismatch fs=%d subfr=%d len=%u\n",fs,subfr,len);return 0;}
  pulse_checks++;pulses_compared+=padded;
 }
 return 1;
}
static int unpack(void){
 const int rates[3]={8,12,16};
 for(unsigned r=0;r<3;r++)for(int index=0;index<32;index++){
  int order=rates[r]==16?16:10;opus_int16 ea[18],eb[18];unsigned char pa[18],pb[18];
  for(int i=0;i<18;i++){ea[i]=eb[i]=-12345;pa[i]=pb[i]=0xda;}
  const silk_NLSF_CB_struct *cb=rates[r]==16?&silk_NLSF_CB_WB:&silk_NLSF_CB_NB_MB;
  silk_NLSF_unpack(ea+1,pa+1,cb,index);
  Unpack request={eb+1,pb+1,rates[r],index,order,order},saved=request;
  if(!op_silk_nlsf_unpack(&request)||memcmp(&request,&saved,sizeof(request))||memcmp(ea,eb,sizeof(ea))||memcmp(pa,pb,sizeof(pa))||eb[0]!=-12345||eb[order+1]!=-12345||pb[0]!=0xda||pb[order+1]!=0xda)return 0;
  unpack_checks++;
 }
 return 1;
}
static int invalid(void){
 unsigned char payload[16]={0};ec_dec ec;memset(&ec,0,sizeof(ec));ec_dec_init(&ec,payload,16);
 Previous state={100,2};SideInfoIndices out;memset(&out,0xa5,sizeof(out));
 Indices good={&ec,&state,&out,16,4,1,0,2,36,8};
 for(unsigned k=0;k<30;k++){
  Indices r=good;Previous initial_state=state;ec_dec initial_ec=ec;
  switch(k){case 0:r.ec=NULL;break;case 1:r.state=NULL;break;case 2:r.out=NULL;break;
   case 3:r.fs=0;break;case 4:r.fs=24;break;case 5:r.subfr=1;break;case 6:r.subfr=3;break;
   case 7:r.vad=2;break;case 8:r.lbrr=-1;break;case 9:r.cond=3;break;case 10:r.out_cap=35;break;case 11:r.state_cap=7;break;
   case 12:state.lag=-32769;break;case 13:state.lag=32768;break;case 14:state.signal=-1;break;case 15:state.signal=3;break;
   case 16:ec.buf=NULL;break;case 17:ec.storage=1276;break;case 18:ec.offs=17;break;case 19:ec.end_offs=17;break;
   case 20:ec.rng=0;break;case 21:ec.rng=0x80000000u+1;break;case 22:ec.val=ec.rng;break;case 23:ec.nend_bits=33;break;case 24:ec.nbits_total=32769;break;
   case 25:r.vad=-1;break;case 26:r.cond=-1;break;case 27:r.fs=-1;break;case 28:ec.rng=0x800000;break;case 29:r.subfr=-1;break;}
  Indices saved=r;Previous saved_state=state;SideInfoIndices saved_out=out;ec_dec saved_ec=ec;
  if(op_silk_indices(&r)||memcmp(&r,&saved,sizeof(r))||memcmp(&state,&saved_state,sizeof(state))||memcmp(&out,&saved_out,sizeof(out))||memcmp(&ec,&saved_ec,sizeof(ec))){printf("SILK indices guard %u failed\n",k);return 0;}
  state=initial_state;ec=initial_ec;invalid_checks++;
 }
 opus_int16 ix[16];unsigned char pred[16];memset(ix,0xa5,sizeof(ix));memset(pred,0xa5,sizeof(pred));
 Unpack ugood={ix,pred,16,0,16,16};
 for(unsigned k=0;k<8;k++){
  Unpack r=ugood;
  switch(k){case 0:r.ec_ix=NULL;break;case 1:r.pred=NULL;break;case 2:r.fs=48;break;case 3:r.index=-1;break;case 4:r.index=32;break;case 5:r.ec_cap=15;break;case 6:r.pred_cap=15;break;case 7:r.fs=0;break;}
  Unpack saved=r;opus_int16 saved_ix[16];unsigned char saved_pred[16];memcpy(saved_ix,ix,sizeof(ix));memcpy(saved_pred,pred,sizeof(pred));
  if(op_silk_nlsf_unpack(&r)||memcmp(&r,&saved,sizeof(r))||memcmp(ix,saved_ix,sizeof(ix))||memcmp(pred,saved_pred,sizeof(pred)))return 0;
  invalid_checks++;
 }
 if(op_silk_indices(NULL)||op_silk_nlsf_unpack(NULL))return 0;invalid_checks+=2;return 1;
}
int main(void){
 const int rates[3]={8,12,16};unsigned char payload[1275];
 for(unsigned k=0;k<4096;k++){
  unsigned len=k%16==0?0:k%16==1?1:k%16==2?2:k%16==3?1275:next()%1276;
  for(unsigned i=0;i<len;i++)payload[i]=k%8==0?0:k%8==1?255:(unsigned char)next();
  for(unsigned rate=0;rate<3;rate++)for(int subfr=2;subfr<=4;subfr+=2){
   int lag=k%64==0?-32768:k%64==1?32767:(int)(next()%301)-20,signal=k%3;
   if(!trial(payload,len,rates[rate],subfr,lag,signal,k%12,k%7==0?1+k%9:0))return 1;
  }
 }
 if(!unpack()||!invalid())return 1;
 printf("SILK indices: %u exact side-information/state frames (%u voiced, %u conditional voiced, %u primed), %u connected excitation frames/%llu pulses, %u NLSF unpack vectors, %u guards\n",index_checks,voiced_checks,conditional_voiced_checks,primed_checks,pulse_checks,pulses_compared,unpack_checks,invalid_checks);
 return 0;
}
