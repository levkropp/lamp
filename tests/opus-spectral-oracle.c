/* Test-only normative RFC6716 anti-collapse and denormalization comparison. */
#include "lamp-test.h"
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <math.h>
#include "modes.c"
#include "bands.c"
#include "quant_bands.h"
typedef struct {
 float *x;unsigned char *masks;float *energy,*prev1,*prev2;int *pulses;
 int lm,channels,size,start,end;uint32_t seed;unsigned x_cap,mask_cap,energy_cap,pulse_cap;
} Anti;
typedef struct {
 float *x,*freq,*energy,*gains;int channels,lm,start,end,downsample;
 unsigned x_cap,freq_cap,energy_cap,gain_cap;
} Denorm;
LAMP_ABI int op_celt_anti_collapse(Anti *);
LAMP_ABI int op_celt_denormalize(Denorm *);
LAMP_ABI float op_celt_exp2(float);
static uint32_t rng=0x243ac132;
static uint32_t next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static unsigned exp_checks,anti_checks,denorm_checks,guards,coefficients,max_ulp;
static float max_anti_error,max_relative;
static int compare(const float *a,const float *b,int n,int anti){
 for(int i=0;i<n;i++){
  float error=fabsf(a[i]-b[i]),relative=error/fmaxf(1e-30f,fabsf(a[i]));
  coefficients++;if(anti&&error>max_anti_error)max_anti_error=error;if(!anti&&relative>max_relative)max_relative=relative;
  if(!isfinite(a[i])||!isfinite(b[i])||error>(anti?0.000003f:3e-7f*fabsf(a[i])+2e-44f)){
   printf("Coefficient mismatch %d: %.9g/%.9g error %.9g relative %.9g anti=%d\n",i,a[i],b[i],error,relative,anti);return 0;
  }
 }return 1;
}
static int exponent(float x){
 float expected=(float)exp(0.6931471805599453094*(double)x),actual=op_celt_exp2(x);
 uint32_t a,b;memcpy(&a,&expected,4);memcpy(&b,&actual,4);unsigned difference=a>b?a-b:b-a;
 if(difference>max_ulp)max_ulp=difference;
 if(difference>1){printf("Exponent mismatch x=%.9g expected %.9g actual %.9g ULP=%u\n",x,expected,actual,difference);return 0;}
 exp_checks++;return 1;
}
static int trial(int lm,int C,int start,int end,int kind,int downsample){
 int M=1<<lm,N=120*M,count=C*N;
 float xa[1922],xb[1922],fa[1922],fb[1922],ea[44],eb[44],ga[44],gb[44],prev1[42],prev2[42];
 unsigned char masks[42],mask_copy[42];int pulses[21],pulse_copy[21];
 for(int i=0;i<1922;i++){xa[i]=xb[i]=((int)(next()%2001)-1000)*.0001f;fa[i]=fb[i]=123456.f;}
 xa[0]=xb[0]=xa[count+1]=xb[count+1]=123456.f;
 for(int i=0;i<44;i++)ea[i]=eb[i]=ga[i]=gb[i]=123456.f;
 for(int i=0;i<42;i++){
  ea[i+1]=eb[i+1]=kind==0?-28.f:kind==1?0.f:kind==2?-160.f:kind==3?90.f:((int)(next()%12001)-6000)*.01f;
  prev1[i]=((int)(next()%32001)-16000)*.01f;prev2[i]=((int)(next()%32001)-16000)*.01f;
  masks[i]=kind==0?0:kind==1?(1<<M)-1:(unsigned char)(next()%((1<<M)));
 }
 for(int i=0;i<21;i++)pulses[i]=kind==0?0:kind==1?81600:next()%81601;
 memcpy(mask_copy,masks,sizeof(masks));memcpy(pulse_copy,pulses,sizeof(pulses));
 uint32_t seed=next();Anti request={xb+1,masks,eb+1,prev1,prev2,pulses,lm,C,N,start,end,seed,count,C*21,42,21},saved=request;
 anti_collapse(&mode48000_960_120,xa+1,masks,lm,C,N,start,end,ea+1,prev1,prev2,pulses,seed);
 if(!op_celt_anti_collapse(&request)||memcmp(&request,&saved,sizeof(saved))||memcmp(masks,mask_copy,sizeof(masks))||memcmp(pulses,pulse_copy,sizeof(pulses))||memcmp(ea,eb,sizeof(ea))||xb[0]!=123456.f||xb[count+1]!=123456.f||!compare(xa+1,xb+1,count,1)){
  printf("Anti-collapse mismatch LM=%d C=%d start/end=%d/%d kind=%d\n",lm,C,start,end,kind);return 0;
 }
 anti_checks++;
 log2Amp(&mode48000_960_120,start,end,ga+1,ea+1,C);
 denormalise_bands(&mode48000_960_120,xa+1,fa+1,ga+1,end,C,M);
 for(int c=0;c<C;c++){
  for(int i=0;i<M*mode48000_960_120.eBands[start];i++)fa[1+c*N+i]=0;
  for(int i=N/downsample;i<N;i++)fa[1+c*N+i]=0;
 }
 Denorm d={xb+1,fb+1,eb+1,gb+1,C,lm,start,end,downsample,count,count,C*21,C*21},dsaved=d;
 if(!op_celt_denormalize(&d)||memcmp(&d,&dsaved,sizeof(d))||fb[0]!=123456.f||fb[count+1]!=123456.f||gb[0]!=123456.f||gb[C*21+1]!=123456.f||!compare(ga+1,gb+1,C*21,0)||!compare(fa+1,fb+1,count,0)){
  printf("Denormalization mismatch LM=%d C=%d start/end=%d/%d kind=%d rate=%d\n",lm,C,start,end,kind,downsample);return 0;
 }
 denorm_checks++;return 1;
}
static int invalid(void){
 float x[1920],copy[1920],freq[1920],energies[42],gains[42],prev1[42]={0},prev2[42]={0};unsigned char masks[42]={0};int pulses[21]={0};
 for(int i=0;i<1920;i++)x[i]=copy[i]=freq[i]=1.f;for(int i=0;i<42;i++)energies[i]=gains[i]=1.f;
 Anti good={x,masks,energies,prev1,prev2,pulses,3,2,960,0,21,128,1920,42,42,21};
 for(unsigned t=0;t<30;t++){
  Anti request=good,saved;
  if(t<6)((void**)&request)[t]=NULL;
  else switch(t){case 6:request.lm=4;break;case 7:request.channels=0;break;case 8:request.channels=3;break;case 9:request.size=959;break;
   case 10:request.start=-1;break;case 11:request.end=22;break;case 12:request.end=0;break;case 13:request.x_cap=1919;break;
   case 14:request.mask_cap=41;break;case 15:request.energy_cap=41;break;case 16:request.pulse_cap=20;break;
   case 17:energies[41]=NAN;break;case 18:prev1[41]=INFINITY;break;case 19:prev2[41]=-INFINITY;break;
   case 20:energies[41]=160.01f;break;case 21:prev1[41]=-160.01f;break;case 22:prev2[41]=160.01f;break;
   case 23:pulses[20]=-1;break;case 24:pulses[20]=81601;break;case 25:x[799]=NAN;break;case 26:x[799]=2.01f;break;
   case 27:request.lm=0;request.size=120;request.channels=1;masks[20]=2;break;case 28:request.start=21;break;case 29:request.lm=-1;break;
  }
  saved=request;
  if(op_celt_anti_collapse(&request)||memcmp(&request,&saved,sizeof(saved))){printf("Anti guard %u failed\n",t);return 0;}
  for(int i=0;i<1920;i++)if(i!=799&&x[i]!=copy[i])return 0;
  energies[41]=1.f;prev1[41]=prev2[41]=0;pulses[20]=0;x[799]=1.f;masks[20]=0;guards++;
 }
 Denorm dgood={x,freq,energies,gains,2,3,0,21,1,1920,1920,42,42};
 for(unsigned t=0;t<25;t++){
  Denorm d=dgood,saved;
  if(t<4)((void**)&d)[t]=NULL;
  else switch(t){case 4:d.channels=0;break;case 5:d.channels=3;break;case 6:d.lm=4;break;case 7:d.start=-1;break;case 8:d.end=22;break;
   case 9:d.end=0;break;case 10:d.downsample=0;break;case 11:d.downsample=5;break;case 12:d.downsample=7;break;
   case 13:d.x_cap=1919;break;case 14:d.freq_cap=1919;break;case 15:d.energy_cap=41;break;case 16:d.gain_cap=41;break;
   case 17:energies[41]=NAN;break;case 18:energies[41]=160.01f;break;case 19:energies[41]=97.f;break;
   case 20:x[799]=NAN;break;case 21:x[799]=2.01f;break;case 22:d.start=21;break;case 23:d.lm=-1;break;case 24:d.downsample=-1;break;
  }
  saved=d;if(op_celt_denormalize(&d)||memcmp(&d,&saved,sizeof(saved))||memcmp(freq,copy,sizeof(freq))){printf("Denorm guard %u failed\n",t);return 0;}
  for(int i=0;i<42;i++)if(gains[i]!=1.f)return 0;
  energies[41]=1.f;x[799]=1.f;guards++;
 }
 if(op_celt_anti_collapse(NULL)||op_celt_denormalize(NULL))return 0;guards+=2;return 1;
}
int main(void){
 if(sizeof(Anti)!=88||sizeof(Denorm)!=72)return 2;
 if(!invalid())return 1;
 for(int i=-655360;i<=524288;i++)if(!exponent(i/4096.f))return 1;
 for(unsigned t=0;t<131072;t++){float x=((int)(next()%10400001)-6400000)*.000025f;if(!exponent(x))return 1;}
 const int rates[]={1,2,3,4,6};
 for(int lm=0;lm<4;lm++)for(int C=1;C<=2;C++)for(int kind=0;kind<8;kind++)for(unsigned r=0;r<5;r++)for(int end=1;end<=21;end++){
  if(!trial(lm,C,0,end,kind,rates[r])||!trial(lm,C,end-1,end,kind,rates[r]))return 1;
 }
 for(unsigned t=0;t<8192;t++){int start=next()%21,end=start+1+next()%(21-start);if(!trial(next()%4,1+next()%2,start,end,4+next()%4,rates[next()%5]))return 1;}
 printf("Passed %u exponent comparisons (max %u ULP), %u anti-collapse and %u denormalization frames, %u coefficients and %u invalid guards; max anti error %.9g, max relative spectral error %.9g.\n",exp_checks,max_ulp,anti_checks,denorm_checks,coefficients,guards,max_anti_error,max_relative);return 0;
}
