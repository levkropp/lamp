/* Test-only comparisons against unchanged normative RFC6716 SILK sources. */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "main.h"
#include "tables.h"
typedef struct {void *ar;int order,chirp;unsigned cap;int width;} Expand;
typedef struct {const opus_int16 *ar;int order;unsigned cap;} Inverse;
typedef struct {const opus_int16 *nlsf;opus_int16 *out;int order;unsigned in_cap,out_cap;} Convert;
typedef struct {const opus_int8 *ind;opus_int16 *out;void *work;int fs;unsigned ind_cap,out_cap,work_cap;} Nlsf;
typedef struct {int lag,signal;} Previous;
typedef struct {ec_dec *ec;Previous *state;SideInfoIndices *out;int fs,subfr,vad,lbrr,cond;unsigned out_cap,state_cap;} Indices;
int op_silk_inverse32(int,int);
int op_silk_bwexpand(Expand *);
int op_silk_lpc_inverse(Inverse *);
int op_silk_nlsf2a(Convert *);
int op_silk_nlsf_decode(Nlsf *);
int op_silk_indices(Indices *);
static uint32_t rng=0x219fcb4a;
static uint32_t next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static unsigned reciprocal_checks,expand_checks,gain_checks,convert_checks,connected_checks,skipped_invalid,guards;
static unsigned long long coefficients;
static int reciprocal(void){
 for(int q=1;q<=61;q++){
  for(int b=-2048;b<=2048;b++)if(b){
   int a=silk_INVERSE32_varQ(b,q),v=op_silk_inverse32(b,q);
   if(a!=v){printf("Reciprocal b=%d q=%d %d/%d\n",b,q,a,v);return 0;}reciprocal_checks++;
  }
  for(unsigned i=0;i<8192;i++){
   int b=(int)next();if(!b||b==INT32_MIN)b=INT32_MAX;
   if(i<62){b=1<<(i/2);if(i%2)b=-b;}
   int a=silk_INVERSE32_varQ(b,q),v=op_silk_inverse32(b,q);
   if(a!=v){printf("Random reciprocal b=%d q=%d %d/%d\n",b,q,a,v);return 0;}reciprocal_checks++;
  }
 }
 return 1;
}
static int expand(int order,int chirp,int width){
 int32_t a32[18],b32[18];int16_t a16[18],b16[18];
 memset(a32,0xa5,sizeof(a32));memcpy(b32,a32,sizeof(a32));memset(a16,0xa5,sizeof(a16));memcpy(b16,a16,sizeof(a16));
 for(int i=1;i<=order;i++){a32[i]=b32[i]=(int32_t)next();a16[i]=b16[i]=(int16_t)next();}
 Expand request={width==16?(void *)(b16+1):(void *)(b32+1),order,chirp,order,width},saved=request;
 if(width==16)silk_bwexpander(a16+1,order,chirp);else silk_bwexpander_32(a32+1,order,chirp);
 if(!op_silk_bwexpand(&request)||memcmp(&request,&saved,sizeof(request))||memcmp(a16,b16,sizeof(a16))||memcmp(a32,b32,sizeof(a32))){printf("Bandwidth order=%d chirp=%d width=%d\n",order,chirp,width);return 0;}
 expand_checks++;coefficients+=order;return 1;
}
static int gain(const int16_t *x,int order){
 int16_t saved[16];memcpy(saved,x,order*2);Inverse request={x,order,order},prior=request;
 int a=silk_LPC_inverse_pred_gain(x,order),b=op_silk_lpc_inverse(&request);
 if(a!=b||memcmp(x,saved,order*2)||memcmp(&request,&prior,sizeof(request))){printf("Gain order=%d %d/%d\n",order,a,b);return 0;}
 gain_checks++;return 1;
}
static int convert(const int16_t *x,int order){
 int16_t a[18],b[18],saved[16];memcpy(saved,x,order*2);
 for(int i=0;i<18;i++)a[i]=b[i]=-12345;
 silk_NLSF2A(a+1,x,order);
 Convert request={x,b+1,order,order,order},prior=request;
 if(!op_silk_nlsf2a(&request)||memcmp(a,b,sizeof(a))||memcmp(x,saved,order*2)||memcmp(&request,&prior,sizeof(request))){
  printf("Conversion order=%d case=%u\n",order,convert_checks);
  for(int i=0;i<order;i++)if(a[i+1]!=b[i+1])printf("coef%d %d/%d\n",i,a[i+1],b[i+1]);return 0;
 }
 if(!gain(b+1,order))return 0;
 if(silk_LPC_inverse_pred_gain(b+1,order)<SILK_FIX_CONST(1.0/MAX_PREDICTION_POWER_GAIN,30)){puts("Converted filter unstable");return 0;}
 convert_checks++;coefficients+=order;return 1;
}
static int standalone(void){
 if(!reciprocal())return 0;
 for(int order=1;order<=16;order++)for(int width=16;width<=32;width+=16){
  const int chirps[]={0,1,32767,32768,32769,65534,65535,65536};
  for(unsigned i=0;i<sizeof(chirps)/sizeof(*chirps);i++)if(!expand(order,chirps[i],width))return 0;
  for(unsigned i=0;i<512;i++)if(!expand(order,next()%65537,width))return 0;
 }
 for(int order=10;order<=16;order+=6)for(unsigned trial=0;trial<16384;trial++){
  int16_t x[16];
  for(int i=0;i<order;i++){
   switch(trial%8){
    case 0:x[i]=0;break;case 1:x[i]=32767;break;case 2:x[i]=(int16_t)((order-i)*32767/order);break;
    case 3:x[i]=(int16_t)(next()%32768);break;case 4:x[i]=(int16_t)(16000+i%2);break;
    case 5:x[i]=(int16_t)(i*32767/(order-1));break;case 6:x[i]=(int16_t)(32767*(i%2));break;
    default:x[i]=(int16_t)((i+1)*32768/(order+1));break;
   }
  }
  if(!convert(x,order))return 0;
  for(int i=0;i<order;i++)x[i]=(int16_t)(trial%4==0?next():trial%4==1?(int)(next()%8192)-4096:trial%4==2?0:(int)(next()%256)-128);
  if(!gain(x,order))return 0;
 }
 return 1;
}
static int decoded(const int8_t *indices,int fs){
 const silk_NLSF_CB_struct *cb=fs==16?&silk_NLSF_CB_WB:&silk_NLSF_CB_NB_MB;
 int16_t a[16],b[16];unsigned char work[112];silk_NLSF_decode(a,indices,cb);
 Nlsf request={indices,b,work,fs,cb->order+1,cb->order,112};
 int valid=op_silk_nlsf_decode(&request);if(memcmp(a,b,cb->order*2)){puts("Connected NLSF mismatch");return 0;}
 if(!valid){skipped_invalid++;return 1;}
 if(!convert(b,cb->order))return 0;connected_checks++;return 1;
}
static int connected(void){
 const int rates[]={8,12,16};
 for(int r=0;r<3;r++)for(int cb=0;cb<32;cb++)for(unsigned trial=0;trial<64;trial++){
  int8_t indices[17]={0};indices[0]=(int8_t)cb;
  for(int i=1;i<=(rates[r]==16?16:10);i++)indices[i]=(int8_t)(trial%4==0?0:trial%4==1?-10:trial%4==2?10:(int)(next()%21)-10);
  if(!decoded(indices,rates[r]))return 0;
 }
 unsigned char payload[1275];
 for(unsigned trial=0;trial<8192;trial++){
  unsigned len=trial%8==0?0:trial%8==1?1:trial%8==2?1275:next()%1276;
  for(unsigned i=0;i<len;i++)payload[i]=(unsigned char)next();
  int fs=rates[trial%3],subfr=trial%2?2:4;
  silk_decoder_state state;memset(&state,0,sizeof(state));state.fs_kHz=fs;state.nb_subfr=subfr;state.LPC_order=fs==16?16:10;
  state.psNLSF_CB=fs==16?&silk_NLSF_CB_WB:&silk_NLSF_CB_NB_MB;
  state.pitch_lag_low_bits_iCDF=fs==8?silk_uniform4_iCDF:fs==12?silk_uniform6_iCDF:silk_uniform8_iCDF;
  state.pitch_contour_iCDF=fs==8?(subfr==2?silk_pitch_contour_10_ms_NB_iCDF:silk_pitch_contour_NB_iCDF):(subfr==2?silk_pitch_contour_10_ms_iCDF:silk_pitch_contour_iCDF);
  state.ec_prevLagIndex=100;state.ec_prevSignalType=2;Previous previous={100,2};SideInfoIndices indices;memset(&indices,0xa5,sizeof(indices));state.indices=indices;
  for(int frame=0;frame<4;frame++){
   ec_dec ea,eb;memset(&ea,0,sizeof(ea));ec_dec_init(&ea,payload,len);eb=ea;
   int vad=(trial+frame)%2,lbrr=(trial/2+frame)%2,cond=(trial+frame)%3;state.VAD_flags[frame%3]=(int8_t)vad;
   if(trial%3==0){ec_dec_bit_logp(&ea,3);ec_dec_bit_logp(&eb,3);}
   silk_decode_indices(&state,&ea,frame%3,lbrr,cond);
   Indices request={&eb,&previous,&indices,fs,subfr,vad,lbrr,cond,36,8};
   if(!op_silk_indices(&request)||memcmp(&indices,&state.indices,sizeof(indices))||memcmp(&ea,&eb,sizeof(ea))||!decoded(indices.NLSFIndices,fs))return 0;
  }
 }
 return 1;
}
static int invalid(void){
 int16_t input[16]={0},out[16];int32_t ar[16];memset(out,0xa5,sizeof(out));memset(ar,0xa5,sizeof(ar));
 Convert good={input,out,16,16,16};
 for(unsigned i=0;i<9;i++){
  Convert request=good;if(i==0)request.nlsf=NULL;if(i==1)request.out=NULL;if(i==2)request.order=12;if(i==3)request.in_cap=15;if(i==4)request.out_cap=15;if(i==5)input[0]=-1;if(i==6)input[15]=INT16_MIN;if(i==7)request.order=0;if(i==8)request.order=-1;
  Convert saved=request;int16_t prior[16];memcpy(prior,out,sizeof(out));
  if(op_silk_nlsf2a(&request)||memcmp(&request,&saved,sizeof(request))||memcmp(out,prior,sizeof(out)))return 0;
  memset(input,0,sizeof(input));guards++;
 }
 Expand base={ar,16,65535,16,32};
 for(unsigned i=0;i<8;i++){
  Expand request=base;if(i==0)request.ar=NULL;if(i==1)request.order=0;if(i==2)request.order=17;if(i==3)request.chirp=-1;if(i==4)request.chirp=65537;if(i==5)request.cap=15;if(i==6)request.width=8;if(i==7)request.order=-1;
  Expand saved=request;int32_t prior[16];memcpy(prior,ar,sizeof(ar));
  if(op_silk_bwexpand(&request)||memcmp(&request,&saved,sizeof(request))||memcmp(prior,ar,sizeof(ar)))return 0;guards++;
 }
 Inverse ig={input,16,16};
 for(unsigned i=0;i<4;i++){
  Inverse request=ig;if(i==0)request.ar=NULL;if(i==1)request.order=12;if(i==2)request.cap=15;if(i==3)request.order=0;
  Inverse saved=request;if(op_silk_lpc_inverse(&request)||memcmp(&request,&saved,sizeof(request)))return 0;guards++;
 }
 if(op_silk_inverse32(0,30)||op_silk_inverse32(INT32_MIN,30)||op_silk_inverse32(1,0)||op_silk_inverse32(1,62)||op_silk_nlsf2a(NULL)||op_silk_bwexpand(NULL)||op_silk_lpc_inverse(NULL))return 0;guards+=7;
 return 1;
}
int main(void){
 if(!standalone()||!connected()||!invalid())return 1;
 printf("SILK LPC: %u exact reciprocals, %u int16/int32 bandwidth expansions, %u inverse prediction gains, %u NLSF-to-LPC vectors (%u connected NLSF, %u invalid NLSF results discarded), %llu coefficients, %u guards\n",reciprocal_checks,expand_checks,gain_checks,convert_checks,connected_checks,skipped_invalid,coefficients,guards);
 return 0;
}
