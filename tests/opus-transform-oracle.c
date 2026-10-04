/* Test-only normative CELT FFT/MDCT comparison, no reference runtime linkage. */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include "modes.c"
#include "kiss_fft.h"
#include "mdct.h"
#include "celt.h"
#include "celt-synthesis-reference.inc"
typedef struct {float *in,*out,*scratch;int lm,stride;unsigned in_cap,out_cap,scratch_cap;} Mdct;
typedef struct {float *freq,*out,*overlap,*scratch;int channels,lm,short_blocks;unsigned freq_cap,out_cap,overlap_cap,scratch_cap;} Synthesis;
int op_celt_ifft(const kiss_fft_cpx *,kiss_fft_cpx *,int);
int op_celt_imdct(Mdct *);
int op_celt_synthesis(Synthesis *);
static uint32_t rng=0x5a171354;
static uint32_t next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static unsigned fft_checks,mdct_checks,synthesis_checks,guards,coefficient_checks;
static double max_fft_error,max_mdct_error,max_synthesis_error;
static int fft(int lm,int pattern){
 int n=60<<lm;kiss_fft_cpx input[480]={{0}},original[480],a[482],b[482];
 float scale=pattern<8?1.f:pattern<10?1e20f:1e-20f;
 for(int i=0;i<n;i++){
  input[i].r=pattern==0?0:pattern==1?1:pattern==2?(i==0):((int)(next()%20001)-10000)*.0001f*scale;
  input[i].i=pattern<3?0:((int)(next()%20001)-10000)*.0001f*scale;
 }
 memcpy(original,input,sizeof(input));for(int i=0;i<482;i++)a[i].r=a[i].i=b[i].r=b[i].i=123456.f;
 opus_ifft(mode48000_960_120.mdct.kfft[3-lm],input,a+1);
 int ok=op_celt_ifft(input,b+1,lm);
 if(!ok||memcmp(input,original,sizeof(input))||b[0].r!=123456.f||b[0].i!=123456.f||b[n+1].r!=123456.f||b[n+1].i!=123456.f){puts("FFT input/canary guard failed");return 0;}
 for(int i=0;i<2*n;i++){
  float expected=((float*)(a+1))[i],actual=((float*)(b+1))[i];double error=fabs((double)expected-actual)/scale;
  coefficient_checks++;if(error>max_fft_error)max_fft_error=error;
  if(!isfinite(actual)||error>0.00003){printf("IFFT mismatch LM=%d pattern=%d sample=%d expected %.9g actual %.9g scaled error %.9g\n",lm,pattern,i,expected,actual,error);return 0;}
 }
 fft_checks++;return 1;
}
static int invalid(void){
 kiss_fft_cpx in[480]={{0}},out[480],saved[480];for(int i=0;i<480;i++)out[i].r=out[i].i=saved[i].r=saved[i].i=1.f;
 if(op_celt_ifft(NULL,out,3)||op_celt_ifft(in,NULL,3)||op_celt_ifft(in,out,-1)||op_celt_ifft(in,out,4)||op_celt_ifft(in,in,3)||memcmp(out,saved,sizeof(out)))return 0;guards+=5;
 const float bad[]={NAN,INFINITY,-INFINITY,1e34f};
 for(unsigned i=0;i<4;i++){in[479].i=bad[i];if(op_celt_ifft(in,out,3)||memcmp(out,saved,sizeof(out)))return 0;guards++;}return 1;
}
static int floats(const float *a,const float *b,unsigned count,float scale,double *max_error){
 for(unsigned i=0;i<count;i++){
  double error=fabs((double)a[i]-b[i])/scale;coefficient_checks++;if(error>*max_error)*max_error=error;
  if(!isfinite(b[i])||error>.00003){printf("Transform sample %u: %.9g/%.9g scaled error %.9g\n",i,a[i],b[i],error);return 0;}
 }return 1;
}
static int mdct(int lm,int stride,int pattern){
 int n=120<<lm,input_count=(n-1)*stride+1;
 float input[7680],original[7680],a[1082],b[1082],scratch[1922];
 float scale=pattern<8?1.f:pattern<10?1e20f:1e-20f;
 for(int i=0;i<input_count;i++)input[i]=pattern==0?0:pattern==1?1:pattern==2?(i==0):((int)(next()%20001)-10000)*.0001f*scale;
 memcpy(original,input,input_count*4);
 for(int i=0;i<1082;i++)a[i]=b[i]=123456.f;
 for(int i=0;i<120;i++)a[i+1]=b[i+1]=((int)(next()%2001)-1000)*.0001f*scale;
 for(int i=0;i<1922;i++)scratch[i]=123456.f;
 clt_mdct_backward(&mode48000_960_120.mdct,input,a+1,mode48000_960_120.window,120,3-lm,stride);
 Mdct request={input,b+1,scratch+1,lm,stride,input_count,n+120,2*n},saved=request;
 if(!op_celt_imdct(&request)||memcmp(&request,&saved,sizeof(saved))||memcmp(input,original,input_count*4)||b[0]!=123456.f||b[n+121]!=123456.f||scratch[0]!=123456.f||scratch[2*n+1]!=123456.f||!floats(a+1,b+1,n+120,scale,&max_mdct_error)){
  printf("MDCT mismatch LM=%d stride=%d pattern=%d\n",lm,stride,pattern);return 0;
 }mdct_checks++;return 1;
}
static int synthesis(int C,int lm,int transient,float *oa,float *ob){
 int n=120<<lm;float freq[1920],original[1920],a[1922],b[1922],scratch[3002];
 for(int i=0;i<n*C;i++)freq[i]=((int)(next()%20001)-10000)*.0001f;
 memcpy(original,freq,n*C*4);for(int i=0;i<1922;i++)a[i]=b[i]=123456.f;for(int i=0;i<3002;i++)scratch[i]=123456.f;
 float *outs[2]={a+1,a+1+n},*overlaps[2]={oa+1,oa+121};
 reference_synthesis(&mode48000_960_120,transient?(1<<lm):0,freq,outs,overlaps,C,lm);
 Synthesis request={freq,b+1,ob+1,scratch+1,C,lm,transient,n*C,n*C,120*C,3*n+120},saved=request;
 if(!op_celt_synthesis(&request)||memcmp(&request,&saved,sizeof(saved))||memcmp(freq,original,n*C*4)||b[0]!=123456.f||b[n*C+1]!=123456.f||ob[0]!=123456.f||ob[120*C+1]!=123456.f||scratch[0]!=123456.f||scratch[3*n+121]!=123456.f||!floats(a+1,b+1,n*C,1,&max_synthesis_error)||!floats(oa+1,ob+1,120*C,1,&max_synthesis_error)){
  printf("Overlap synthesis mismatch LM=%d C=%d transient=%d\n",lm,C,transient);return 0;
 }synthesis_checks++;return 1;
}
static int transform_invalid(void){
 float input[1920]={0},out[1920],saved_out[1920],scratch[3000],overlap[240],saved_overlap[240];
 for(int i=0;i<1920;i++)out[i]=saved_out[i]=1.f;for(int i=0;i<3000;i++)scratch[i]=1.f;for(int i=0;i<240;i++)overlap[i]=saved_overlap[i]=1.f;
 Mdct good={input,out,scratch,3,1,960,1080,1920};
 for(unsigned t=0;t<17;t++){
  Mdct request=good,saved;
  if(t<3)((void**)&request)[t]=NULL;
  else switch(t){case 3:request.lm=-1;break;case 4:request.lm=4;break;case 5:request.stride=0;break;case 6:request.stride=3;break;case 7:request.stride=16;break;
   case 8:request.in_cap=959;break;case 9:request.out_cap=1079;break;case 10:request.scratch_cap=1919;break;
   case 11:input[959]=NAN;break;case 12:input[959]=INFINITY;break;case 13:input[959]=1e34f;break;case 14:out[119]=NAN;break;case 15:out[119]=INFINITY;break;case 16:out[119]=1e38f;break;
  }
  saved=request;float last=out[119];
  if(op_celt_imdct(&request)||memcmp(&request,&saved,sizeof(saved))||memcmp(out,saved_out,119*4)||memcmp(out+120,saved_out+120,(1920-120)*4)||memcmp(out+119,&last,4)){printf("MDCT guard %u failed\n",t);return 0;}
  for(int i=0;i<3000;i++)if(scratch[i]!=1.f)return 0;input[959]=0;out[119]=1.f;guards++;
 }
 Synthesis sgood={input,out,overlap,scratch,2,3,1,1920,1920,240,3000};
 for(unsigned t=0;t<21;t++){
  Synthesis request=sgood,saved;
  if(t<4)((void**)&request)[t]=NULL;
  else switch(t){case 4:request.channels=0;break;case 5:request.channels=3;break;case 6:request.lm=-1;break;case 7:request.lm=4;break;case 8:request.short_blocks=-1;break;case 9:request.short_blocks=2;break;
   case 10:request.freq_cap=1919;break;case 11:request.out_cap=1919;break;case 12:request.overlap_cap=239;break;case 13:request.scratch_cap=2999;break;
   case 14:input[1919]=NAN;break;case 15:input[1919]=INFINITY;break;case 16:input[1919]=1e34f;break;case 17:overlap[239]=NAN;break;case 18:overlap[239]=INFINITY;break;case 19:overlap[239]=1e38f;break;case 20:request.channels=-1;break;
  }
  saved=request;float last=overlap[239];
  if(op_celt_synthesis(&request)||memcmp(&request,&saved,sizeof(saved))||memcmp(out,saved_out,sizeof(out))||memcmp(overlap,saved_overlap,239*4)||memcmp(overlap+239,&last,4)){printf("Synthesis guard %u failed\n",t);return 0;}
  for(int i=0;i<3000;i++)if(scratch[i]!=1.f)return 0;input[1919]=0;overlap[239]=1.f;guards++;
 }
 if(op_celt_imdct(NULL)||op_celt_synthesis(NULL))return 0;guards+=2;return 1;
}
int main(void){
 if(sizeof(Mdct)!=48||sizeof(Synthesis)!=64)return 2;
 if(!invalid()||!transform_invalid()){puts("Transform guards failed");return 1;}
 for(int lm=0;lm<4;lm++)for(int pattern=0;pattern<12;pattern++)for(int t=0;t<256;t++)if(!fft(lm,pattern))return 1;
 for(int lm=0;lm<4;lm++)for(int stride=1;stride<=8;stride*=2)for(int pattern=0;pattern<12;pattern++)for(int t=0;t<64;t++)if(!mdct(lm,stride,pattern))return 1;
 for(int C=1;C<=2;C++){
  float oa[242],ob[242];for(int i=0;i<242;i++)oa[i]=ob[i]=((int)(next()%2001)-1000)*.0001f;oa[0]=ob[0]=oa[C*120+1]=ob[C*120+1]=123456.f;
  for(unsigned t=0;t<8192;t++)if(!synthesis(C,next()%4,next()%2,oa,ob))return 1;
 }
 printf("Passed %u inverse FFTs, %u MDCT/TDAC transforms, %u long/transient overlap frames, %u coefficients and %u invalid guards; max scale-adjusted errors FFT %.9g / MDCT %.9g / synthesis %.9g.\n",fft_checks,mdct_checks,synthesis_checks,coefficient_checks,guards,max_fft_error,max_mdct_error,max_synthesis_error);return 0;
}
