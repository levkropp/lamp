/* Test-only normative NLSF reconstruction and stability comparisons.
   Include unchanged NLSF_decode.c to inspect its static residual dequantizer. */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "NLSF_decode.c"
typedef struct {const opus_int8 *ind;opus_int16 *out;void *work;int fs;unsigned ind_cap,out_cap,work_cap;} Nlsf;
typedef struct {opus_int16 *out;int fs;unsigned cap;} Stabilize;
typedef struct {int lag,signal;} Previous;
typedef struct {ec_dec *ec;Previous *state;SideInfoIndices *out;int fs,subfr,vad,lbrr,cond;unsigned out_cap,state_cap;} Indices;
int op_silk_nlsf_decode(Nlsf *);
int op_silk_nlsf_stabilize(Stabilize *);
int op_silk_sqrt_approx(int);
int op_silk_indices(Indices *);
static uint32_t rng=0x5c9182ab;
static uint32_t next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static unsigned sqrt_checks,decode_checks,stability_checks,connected_checks,guards,invalid_vector_checks;
static unsigned long long coefficients;
typedef struct {opus_int16 ix[16];unsigned char pred[16];opus_int16 res[16],weight[16];} Workspace;
typedef struct {uint64_t before;Workspace value;uint64_t after;} WorkGuard;
static int valid_vector(const opus_int16 *x,const silk_NLSF_CB_struct *cb){
 int previous=0;
 for(int i=0;i<cb->order;i++){if(x[i]-previous<cb->deltaMin_Q15[i])return 0;previous=x[i];}
 return 32768-previous>=cb->deltaMin_Q15[cb->order];
}
static int decode(opus_int8 *indices,int fs){
 const silk_NLSF_CB_struct *cb=fs==16?&silk_NLSF_CB_WB:&silk_NLSF_CB_NB_MB;
 int order=cb->order;opus_int16 a[18],b[18],first[16];opus_int8 saved_indices[17];memcpy(saved_indices,indices,17);
 for(int i=0;i<18;i++)a[i]=b[i]=-12345;
 WorkGuard work;memset(&work,0xa5,sizeof(work));work.before=0x13579bdf98765432ULL;work.after=0x2468ace012345678ULL;
 Workspace expected;memset(&expected,0xa5,sizeof(expected));
 silk_NLSF_unpack(expected.ix,expected.pred,cb,indices[0]);
 silk_NLSF_residual_dequant(expected.res,indices+1,expected.pred,cb->quantStepSize_Q16,(opus_int16)order);
 for(int i=0;i<order;i++)first[i]=cb->CB1_NLSF_Q8[indices[0]*order+i]<<7;
 silk_NLSF_VQ_weights_laroia(expected.weight,first,order);
 silk_NLSF_decode(a+1,indices,cb);
 Nlsf request={indices,b+1,&work.value,fs,order+1,order,112},saved=request;
 int valid=valid_vector(a+1,cb),actual=op_silk_nlsf_decode(&request);
 if(actual!=valid||memcmp(&request,&saved,sizeof(request))||memcmp(indices,saved_indices,17)||memcmp(a,b,sizeof(a))||memcmp(&expected,&work.value,sizeof(expected))||b[0]!=-12345||b[order+1]!=-12345||work.before!=0x13579bdf98765432ULL||work.after!=0x2468ace012345678ULL){
  printf("NLSF decode mismatch fs=%d first-stage=%d\n",fs,indices[0]);for(int i=0;i<order;i++)if(a[i+1]!=b[i+1])printf("NLSF%d: %d/%d\n",i,a[i+1],b[i+1]);return 0;
 }
 if(!valid)invalid_vector_checks++;
 coefficients+=order*4;decode_checks++;return 1;
}
static int stability(int fs,int pattern){
 const silk_NLSF_CB_struct *cb=fs==16?&silk_NLSF_CB_WB:&silk_NLSF_CB_NB_MB;
 int order=cb->order;opus_int16 a[18],b[18];for(int i=0;i<18;i++)a[i]=b[i]=-12345;
 for(int i=0;i<order;i++){
  opus_int16 value;
  switch(pattern){case 0:value=0;break;case 1:value=32767;break;case 2:value=(opus_int16)((order-i)*2000);break;case 3:value=(opus_int16)(next()%32768);break;case 4:value=(opus_int16)next();break;case 5:value=(opus_int16)(16000+i%2);break;case 6:value=(opus_int16)(i*32767/(order-1));break;default:value=(opus_int16)(32767*(i%2));break;}
  a[i+1]=b[i+1]=value;
 }
 silk_NLSF_stabilize(a+1,cb->deltaMin_Q15,order);
 Stabilize request={b+1,fs,order},saved=request;
 int valid=valid_vector(a+1,cb),actual=op_silk_nlsf_stabilize(&request);
 if(actual!=valid||memcmp(&request,&saved,sizeof(request))||memcmp(a,b,sizeof(a))||b[0]!=-12345||b[order+1]!=-12345){printf("Stabilization mismatch fs=%d pattern=%d valid=%d actual=%d\n",fs,pattern,valid,actual);return 0;}
 if(!valid)invalid_vector_checks++;
 stability_checks++;coefficients+=order;return 1;
}
static int standalone(void){
 for(int x=-128;x<1048576;x++){if(op_silk_sqrt_approx(x)!=silk_SQRT_APPROX(x)){printf("SQRT mismatch %d\n",x);return 0;}sqrt_checks++;}
 for(int i=0;i<262144;i++){int x=(int)next();if(op_silk_sqrt_approx(x)!=silk_SQRT_APPROX(x)){printf("Random sqrt mismatch x=%d a=%d b=%d\n",x,silk_SQRT_APPROX(x),op_silk_sqrt_approx(x));return 0;}sqrt_checks++;}
 const int rates[3]={8,12,16};
 for(int r=0;r<3;r++)for(int cb=0;cb<32;cb++)for(int trial=0;trial<128;trial++){
  opus_int8 indices[17];memset(indices,0xa5,sizeof(indices));indices[0]=(opus_int8)cb;int order=rates[r]==16?16:10;
  for(int i=1;i<=order;i++)indices[i]=(opus_int8)(trial%8==0?0:trial%8==1?-10:trial%8==2?10:trial%8==3?(i%2?-10:10):(int)(next()%21)-10);
  if(!decode(indices,rates[r])||!stability(rates[r],trial%8))return 0;
 }
 return 1;
}
static int connected(void){
 unsigned char payload[1275];const int rates[3]={8,12,16};
 for(unsigned k=0;k<8192;k++){
  unsigned len=k%8==0?0:k%8==1?1:k%8==2?1275:next()%1276;for(unsigned i=0;i<len;i++)payload[i]=k%16==0?0:k%16==1?255:(unsigned char)next();
  int fs=rates[k%3],subfr=k%2?2:4;Previous previous={100,2};SideInfoIndices ind;memset(&ind,0xa5,sizeof(ind));
  silk_decoder_state state;memset(&state,0,sizeof(state));state.fs_kHz=fs;state.nb_subfr=subfr;state.LPC_order=fs==16?16:10;state.psNLSF_CB=fs==16?&silk_NLSF_CB_WB:&silk_NLSF_CB_NB_MB;
  state.pitch_lag_low_bits_iCDF=fs==8?silk_uniform4_iCDF:fs==12?silk_uniform6_iCDF:silk_uniform8_iCDF;
  state.pitch_contour_iCDF=fs==8?(subfr==2?silk_pitch_contour_10_ms_NB_iCDF:silk_pitch_contour_NB_iCDF):(subfr==2?silk_pitch_contour_10_ms_iCDF:silk_pitch_contour_iCDF);
  state.ec_prevLagIndex=100;state.ec_prevSignalType=2;state.indices=ind;
  for(int frame=0;frame<4;frame++){
   ec_dec ea,eb;memset(&ea,0,sizeof(ea));ec_dec_init(&ea,payload,len);eb=ea;
   int vad=(k+frame)%2,lbrr=(k/2+frame)%2,cond=(k+frame)%3;state.VAD_flags[frame%3]=(opus_int8)vad;
   if(k%3==0){ec_dec_bit_logp(&ea,3);ec_dec_bit_logp(&eb,3);}
   silk_decode_indices(&state,&ea,frame%3,lbrr,cond);
   Indices request={&eb,&previous,&ind,fs,subfr,vad,lbrr,cond,36,8};
   if(!op_silk_indices(&request)||memcmp(&ind,&state.indices,sizeof(ind))||memcmp(&ea,&eb,sizeof(ea))||!decode(ind.NLSFIndices,fs))return 0;
   connected_checks++;
  }
 }
 return 1;
}
static int invalid(void){
 opus_int8 indices[17]={0};opus_int16 out[16];Workspace work;memset(out,0xa5,sizeof(out));memset(&work,0xa5,sizeof(work));
 Nlsf good={indices,out,&work,16,17,16,112};
 for(unsigned k=0;k<13;k++){
  Nlsf r=good;
  switch(k){case 0:r.ind=NULL;break;case 1:r.out=NULL;break;case 2:r.work=NULL;break;case 3:r.fs=24;break;case 4:r.ind_cap=16;break;case 5:r.out_cap=15;break;case 6:r.work_cap=111;break;case 7:indices[0]=-1;break;case 8:indices[0]=32;break;case 9:indices[16]=11;break;case 10:indices[1]=-11;break;case 11:r.fs=0;break;case 12:r.fs=-1;break;}
  Nlsf saved=r;Workspace saved_work=work;opus_int16 saved_out[16];memcpy(saved_out,out,sizeof(out));
  if(op_silk_nlsf_decode(&r)||memcmp(&r,&saved,sizeof(r))||memcmp(out,saved_out,sizeof(out))||memcmp(&work,&saved_work,sizeof(work)))return 0;
  memset(indices,0,sizeof(indices));guards++;
 }
 Stabilize sg={out,16,16};
 for(unsigned k=0;k<4;k++){
  Stabilize r=sg;if(k==0)r.out=NULL;if(k==1)r.fs=0;if(k==2)r.cap=15;if(k==3)r.fs=48;
  Stabilize saved=r;opus_int16 saved_out[16];memcpy(saved_out,out,sizeof(out));
  if(op_silk_nlsf_stabilize(&r)||memcmp(&r,&saved,sizeof(r))||memcmp(out,saved_out,sizeof(out)))return 0;
  guards++;
 }
 if(op_silk_nlsf_decode(NULL)||op_silk_nlsf_stabilize(NULL))return 0;guards+=2;return 1;
}
int main(void){
 if(!standalone()){printf("Standalone failed sqrt=%u decode=%u stability=%u\n",sqrt_checks,decode_checks,stability_checks);return 1;}
 if(!connected()){printf("Connected failed %u\n",connected_checks);return 1;}
 if(!invalid()){puts("Guard failed");return 1;}
 printf("SILK NLSF: %u exact square-root approximations, %u decoded NLSF/residual/weight vectors (%u connected side-information), %u stabilization vectors, %u invalid reference-result rejections, %llu coefficients, %u guards\n",sqrt_checks,decode_checks,connected_checks,stability_checks,invalid_vector_checks,coefficients,guards);
 return 0;
}
