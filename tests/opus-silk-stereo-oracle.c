/* Test-only normative stereo entropy and stateful mid/side reconstruction. */
#include "lamp-test.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "main.h"
#include "tables.h"
#include "entenc.h"
typedef struct {ec_dec *ec;int32_t *out;unsigned kind,out_cap,ec_cap;} StereoIndices;
typedef struct {stereo_dec_state *state;int16_t *mid,*side;const int32_t *pred;int fs,n;unsigned state_cap,mid_cap,side_cap,pred_cap;} Stereo;
LAMP_ABI int op_silk_stereo_indices(StereoIndices *);
LAMP_ABI int op_silk_stereo(Stereo *);
typedef char sizes[(sizeof(StereoIndices)==32&&sizeof(Stereo)==56&&sizeof(stereo_dec_state)==12)?1:-1];
typedef struct {uint64_t before;stereo_dec_state state;uint64_t after;} StateGuard;
static uint32_t seed=0xb616f83d;
static uint32_t next(void){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;}
static unsigned entropy_frames,pcm_frames,connected_frames,exhaustive,guards;
static unsigned long long samples;
static int frame(stereo_dec_state *state,const int32_t *pred,int fs,int n,unsigned pattern){
 int16_t a[324],b[324],x[324],y[324];for(int i=0;i<324;i++){a[i]=x[i]=(int16_t)(pattern%7==0?0:pattern%7==1?32767:pattern%7==2?-32768:pattern%7==3?(i%2?32767:-32768):next());b[i]=y[i]=(int16_t)(pattern%7==0?0:pattern%7==1?-32768:pattern%7==2?32767:next());}
 StateGuard guard;memset(&guard,0xa5,sizeof(guard));guard.before=0x13579bdf98765432ULL;guard.after=0x2468ace012345678ULL;guard.state=*state;StateGuard expected=guard;int32_t saved_pred[2];memcpy(saved_pred,pred,8);
 Stereo r={&guard.state,x+1,y+1,pred,fs,n,12,n+2,n+2,2},saved=r;
 silk_stereo_MS_to_LR(&expected.state,a+1,b+1,pred,fs,n);
 if(!op_silk_stereo(&r)||memcmp(a,x,sizeof(a))||memcmp(b,y,sizeof(b))||memcmp(&guard,&expected,sizeof(guard))||memcmp(pred,saved_pred,8)||memcmp(&r,&saved,sizeof(r))){
  printf("Stereo PCM frame%u fs%d n%d pattern%u\n",pcm_frames,fs,n,pattern);for(int i=0;i<324;i++)if(a[i]!=x[i]||b[i]!=y[i]){printf("sample%d left%d/%d right%d/%d\n",i,a[i],x[i],b[i],y[i]);break;}return 0;
 }
 *state=guard.state;pcm_frames++;samples+=2*n;return 1;
}
static int entropy(void){
 unsigned char payload[1275];const int rates[]={8,12,16};
 for(unsigned trial=0;trial<16384;trial++){
  unsigned len=trial%5==0?0:trial%5==1?1:trial%5==2?1275:next()%1276;for(unsigned i=0;i<len;i++)payload[i]=(unsigned char)(trial%8==0?0:trial%8==1?255:next());
  ec_dec a,b;memset(&a,0,sizeof(a));ec_dec_init(&a,payload,len);b=a;stereo_dec_state state;memset(&state,0,sizeof(state));
  for(unsigned f=0;f<4;f++){
   if(trial%3==0){ec_dec_bit_logp(&a,3);ec_dec_bit_logp(&b,3);}int32_t x[4]={-12345,-12345,-12345,-12345},y[4];memcpy(y,x,sizeof(y));
   silk_stereo_decode_pred(&a,x+1);StereoIndices r={&b,y+1,0,2,64},saved=r;
   if(!op_silk_stereo_indices(&r)||memcmp(x,y,sizeof(x))||memcmp(&a,&b,sizeof(a))||memcmp(&r,&saved,sizeof(r))){printf("Stereo predictors trial%u frame%u\n",trial,f);return 0;}entropy_frames++;
   if(!frame(&state,y+1,rates[(trial+f)%3],rates[(trial+f)%3]*(trial%2?10:20),trial+f))return 0;connected_frames++;
   x[1]=-12345;y[1]=-12345;silk_stereo_decode_mid_only(&a,x+1);r.kind=1;r.out_cap=1;saved=r;
   if(!op_silk_stereo_indices(&r)||memcmp(x,y,sizeof(x))||memcmp(&a,&b,sizeof(a))||memcmp(&r,&saved,sizeof(r))){printf("Stereo mid-only trial%u frame%u\n",trial,f);return 0;}entropy_frames++;
  }
 }return 1;
}
static int synthesis(void){
 const int rates[]={8,12,16};for(int r=0;r<3;r++)for(int length=10;length<=20;length+=10)for(unsigned trial=0;trial<1024;trial++){
  stereo_dec_state state;for(int i=0;i<6;i++)((int16_t *)&state)[i]=(int16_t)next();
  for(unsigned f=0;f<4;f++){int32_t pred[2]={trial%4==0?-32768:trial%4==1?32767:trial%4==2?0:(int16_t)next(),trial%4==0?32767:trial%4==1?-32768:trial%4==2?0:(int16_t)next()};if(!frame(&state,pred,rates[r],rates[r]*length,trial+f))return 0;}
 }return 1;
}
static int codebook(void){
 for(int joint=0;joint<25;joint++)for(int a0=0;a0<3;a0++)for(int b0=0;b0<5;b0++)for(int a1=0;a1<3;a1++)for(int b1=0;b1<5;b1++)for(int flag=0;flag<2;flag++){
  unsigned char payload[32]={0};ec_enc encoder;memset(&encoder,0,sizeof(encoder));ec_enc_init(&encoder,payload,sizeof(payload));
  ec_enc_icdf(&encoder,joint,silk_stereo_pred_joint_iCDF,8);ec_enc_icdf(&encoder,a0,silk_uniform3_iCDF,8);ec_enc_icdf(&encoder,b0,silk_uniform5_iCDF,8);ec_enc_icdf(&encoder,a1,silk_uniform3_iCDF,8);ec_enc_icdf(&encoder,b1,silk_uniform5_iCDF,8);ec_enc_icdf(&encoder,flag,silk_stereo_only_code_mid_iCDF,8);ec_enc_done(&encoder);if(encoder.error)return 0;
  ec_dec a,b;memset(&a,0,sizeof(a));ec_dec_init(&a,payload,sizeof(payload));b=a;int32_t x[2],y[2];silk_stereo_decode_pred(&a,x);StereoIndices r={&b,y,0,2,64};
  if(!op_silk_stereo_indices(&r)||memcmp(x,y,8)||memcmp(&a,&b,sizeof(a))){printf("Stereo codebook joint%d %d/%d %d/%d\n",joint,a0,b0,a1,b1);return 0;}entropy_frames++;
  silk_stereo_decode_mid_only(&a,x);r.kind=1;r.out_cap=1;if(!op_silk_stereo_indices(&r)||x[0]!=flag||memcmp(x,y,8)||memcmp(&a,&b,sizeof(a)))return 0;entropy_frames++;exhaustive++;
 }return 1;
}
static int invalid(void){
 unsigned char payload[1275]={0};ec_dec ec;memset(&ec,0,sizeof(ec));ec_dec_init(&ec,payload,1275);int32_t out[2]={123456,654321};StereoIndices eb={&ec,out,0,2,64};
 for(unsigned k=0;k<16;k++){
  StereoIndices r=eb;ec_dec original=ec;switch(k){case 0:r.ec=NULL;break;case 1:r.out=NULL;break;case 2:r.kind=2;break;case 3:r.kind=UINT32_MAX;break;case 4:r.out_cap=1;break;case 5:r.ec_cap=63;break;case 6:ec.buf=NULL;break;case 7:ec.storage=1276;break;case 8:ec.end_offs=1276;break;case 9:ec.offs=1276;break;case 10:ec.rng=0x800000;break;case 11:ec.rng=0x80000001;break;case 12:ec.val=ec.rng;break;case 13:ec.nend_bits=33;break;case 14:ec.nbits_total=32769;break;case 15:r.kind=1;r.out_cap=0;break;}
  ec_dec prior=ec;StereoIndices saved=r;if(op_silk_stereo_indices(&r)||memcmp(&r,&saved,sizeof(r))||memcmp(&ec,&prior,sizeof(ec))||out[0]!=123456||out[1]!=654321){printf("Stereo entropy guard%u\n",k);return 0;}ec=original;guards++;
 }
 stereo_dec_state state;memset(&state,0xa5,sizeof(state));int16_t mid[322],side[322];memset(mid,0xa5,sizeof(mid));memset(side,0xa5,sizeof(side));int32_t pred[2]={0,0};Stereo base={&state,mid,side,pred,16,320,12,322,322,2};
 for(unsigned k=0;k<16;k++){
  Stereo r=base;switch(k){case 0:r.state=NULL;break;case 1:r.mid=NULL;break;case 2:r.side=NULL;break;case 3:r.pred=NULL;break;case 4:r.fs=24;break;case 5:r.n=0;break;case 6:r.n=319;break;case 7:r.n=321;break;case 8:r.state_cap=11;break;case 9:r.mid_cap=321;break;case 10:r.side_cap=321;break;case 11:r.pred_cap=1;break;case 12:pred[0]=-32769;break;case 13:pred[0]=32768;break;case 14:pred[1]=-32769;break;case 15:pred[1]=32768;break;}
  stereo_dec_state prior=state;int16_t prior_mid[322],prior_side[322];memcpy(prior_mid,mid,sizeof(mid));memcpy(prior_side,side,sizeof(side));int32_t prior_pred[2];memcpy(prior_pred,pred,8);Stereo saved=r;
  if(op_silk_stereo(&r)||memcmp(&r,&saved,sizeof(r))||memcmp(&state,&prior,sizeof(state))||memcmp(mid,prior_mid,sizeof(mid))||memcmp(side,prior_side,sizeof(side))||memcmp(pred,prior_pred,8)){printf("Stereo PCM guard%u\n",k);return 0;}pred[0]=pred[1]=0;guards++;
 }
 if(op_silk_stereo_indices(NULL)||op_silk_stereo(NULL))return 0;guards+=2;return 1;
}
int main(void){if(!entropy()||!synthesis()||!codebook()||!invalid())return 1;printf("SILK stereo: %u exact predictor/mid-only entropy frames (%u exhaustive codebook/flag cases), %u exact PCM/history frames (%u connected predictors), %llu int16 PCM samples, %u guards\n",entropy_frames,exhaustive,pcm_frames,connected_frames,samples,guards);return 0;}
