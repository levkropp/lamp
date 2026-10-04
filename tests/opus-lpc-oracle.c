/* Test-only normative CELT float prediction-kernel comparisons. */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include "celt_lpc.h"
typedef struct {const float *x;float *ac;const float *window;float *scratch;int n,lag,overlap;unsigned x_cap,ac_cap,window_cap,scratch_cap;} Autocorr;
typedef struct {float *out;const float *ac;int order;unsigned out_cap,ac_cap;} Lpc;
typedef struct {const float *x,*coef;float *out,*mem;int n,order;unsigned x_cap,coef_cap,out_cap,mem_cap;} Filter;
int op_celt_autocorr(Autocorr *);
int op_celt_lpc(Lpc *);
int op_celt_fir(Filter *);
int op_celt_iir(Filter *);
static uint32_t rng=0xa872493c;
static uint32_t next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static unsigned ac_checks,lpc_checks,fir_checks,iir_checks,invalid_checks;
static unsigned long long coefficients;
static float max_error;
static int compare(const char *what,const float *a,const float *b,int n){
 for(int i=0;i<n;i++){
  float error=fabsf(a[i]-b[i])/fmaxf(1.f,fabsf(a[i]));
  coefficients++;if(error>max_error)max_error=error;
  if(!isfinite(a[i])||!isfinite(b[i])||error>.00001f){printf("%s[%d] mismatch %.9g/%.9g error %.9g\n",what,i,a[i],b[i],error);return 0;}
 }return 1;
}
static int trial(int n,int order,int overlap,int pattern){
 float x[2050],saved[2050],scratch[2050],window[120],a[27],b[27],la[26],lb[26];
 for(int i=0;i<2050;i++)x[i]=scratch[i]=123456.f;
 for(int i=0;i<n;i++){
  float t=(float)i;
  x[i+1]=pattern==0?0:pattern==1?.5f:pattern==2?sinf(t*.0127f)*32768:pattern==3?((int)(next()%20001)-10000)*.0001f:pattern==4?(i==n/2?32768:0):pattern==5?((int)(next()%20001)-10000)*1e8f:pattern==6?((int)(next()%20001)-10000)*1e-20f:sinf(t*.8f)*100;
 }
 memcpy(saved,x,sizeof(x));
 for(int i=0;i<120;i++)window[i]=sinf((i+.5f)*.012f);
 for(int i=0;i<27;i++)a[i]=b[i]=123456.f;
 for(int i=0;i<26;i++)la[i]=lb[i]=123456.f;
 _celt_autocorr(x+1,a+1,window,overlap,order,n);
 Autocorr request={x+1,b+1,overlap?window:NULL,scratch+1,n,order,overlap,n,order+1,overlap,n},saved_request=request;
 if(!op_celt_autocorr(&request)||memcmp(&request,&saved_request,sizeof(request))||memcmp(x,saved,sizeof(x))||b[0]!=123456.f||b[order+2]!=123456.f||scratch[0]!=123456.f||scratch[n+1]!=123456.f||!compare("AC",a+1,b+1,order+1))return 0;
 ac_checks++;
 /* Normative PLC/pitch noise floor and lag window. */
 a[1]*=1.0001f;b[1]*=1.0001f;
 for(int i=1;i<=order;i++){a[i+1]-=a[i+1]*(.008f*i)*(.008f*i);b[i+1]-=b[i+1]*(.008f*i)*(.008f*i);}
 _celt_lpc(la+1,a+1,order);
 Lpc lpc={lb+1,b+1,order,order,order+1},saved_lpc=lpc;
 if(!op_celt_lpc(&lpc)||memcmp(&lpc,&saved_lpc,sizeof(lpc))||lb[0]!=123456.f||lb[order+1]!=123456.f||!compare("LPC",la+1,lb+1,order))return 0;
 lpc_checks++;
 int count=n>1200?1200:n;
 for(int i=0;i<order;i++){float damping=powf(.95f,(float)(i+1));la[i+1]*=damping;lb[i+1]*=damping;}
 for(int i=0;i<n;i++)if(fabsf(x[i+1])>1e6f)x[i+1]*=1e-10f;
 for(int i=0;i<n;i++)if(fabsf(x[i+1])<1e-10f)x[i+1]=0;
 for(int type=0;type<2;type++)for(int inplace=0;inplace<2;inplace++){
  float xa[1202],xb[1202],ya[1202],yb[1202],ma[26],mb[26];
  for(int i=0;i<1202;i++)xa[i]=xb[i]=ya[i]=yb[i]=123456.f;
  for(int i=0;i<26;i++)ma[i]=mb[i]=123456.f;
  for(int i=0;i<order;i++)ma[i+1]=mb[i+1]=((int)(next()%201)-100)*.001f;
  for(int frame=0;frame<4;frame++){
   for(int i=0;i<count;i++)xa[i+1]=xb[i+1]=x[1+(i+frame)%n];
   float *outa=inplace?xa+1:ya+1,*outb=inplace?xb+1:yb+1;
   if(type)celt_iir(xa+1,la+1,outa,count,order,ma+1);else celt_fir(xa+1,la+1,outa,count,order,ma+1);
   Filter filter={xb+1,lb+1,outb,mb+1,count,order,count,order,count,order},saved_filter=filter;
   int result=type?op_celt_iir(&filter):op_celt_fir(&filter);
   if(!result||memcmp(&filter,&saved_filter,sizeof(filter))||!compare(type?"IIR":"FIR",outa,outb,count)||!compare("filter memory",ma+1,mb+1,order)||xb[0]!=123456.f||xb[count+1]!=123456.f||yb[0]!=123456.f||yb[count+1]!=123456.f||mb[0]!=123456.f||mb[order+1]!=123456.f||(!inplace&&memcmp(xa,xb,sizeof(xa))))return 0;
   if(type)iir_checks++;else fir_checks++;
  }
 }
 return 1;
}
static int invalid(void){
 float x[2048]={0},ac[25]={0},window[120]={0},scratch[2048],out[1200],coef[24]={0},mem[24]={0};
 for(int i=0;i<2048;i++)scratch[i]=123456.f;
 for(int i=0;i<1200;i++)out[i]=123456.f;
 Autocorr good={x,ac,window,scratch,1024,24,120,1024,25,120,1024};
 for(unsigned k=0;k<19;k++){
  Autocorr r=good;
  switch(k){case 0:r.x=NULL;break;case 1:r.ac=NULL;break;case 2:r.window=NULL;break;case 3:r.scratch=NULL;break;
   case 4:r.n=0;break;case 5:r.n=2049;break;case 6:r.lag=-1;break;case 7:r.lag=25;break;case 8:r.lag=24;r.n=24;break;
   case 9:r.overlap=-1;break;case 10:r.overlap=121;break;case 11:r.n=200;break;
   case 12:r.x_cap=1023;break;case 13:r.ac_cap=24;break;case 14:r.window_cap=119;break;case 15:r.scratch_cap=1023;break;
   case 16:x[1023]=NAN;break;case 17:x[0]=INFINITY;break;case 18:window[119]=1.1f;break;}
  Autocorr saved=r;float old_ac[25];memcpy(old_ac,ac,sizeof(ac));
  if(op_celt_autocorr(&r)||memcmp(&r,&saved,sizeof(r))||memcmp(ac,old_ac,sizeof(ac)))return 0;
  for(int i=0;i<2048;i++)if(scratch[i]!=123456.f)return 0;
  x[0]=x[1023]=window[119]=0;invalid_checks++;
 }
 Lpc lgood={out,ac,24,24,25};
 for(unsigned k=0;k<10;k++){
  Lpc r=lgood;
  switch(k){case 0:r.out=NULL;break;case 1:r.ac=NULL;break;case 2:r.order=0;break;case 3:r.order=25;break;case 4:r.out_cap=23;break;case 5:r.ac_cap=24;break;case 6:ac[24]=NAN;break;case 7:ac[0]=INFINITY;break;case 8:ac[0]=-1;break;case 9:ac[24]=1e34f;break;}
  Lpc saved=r;
  if(op_celt_lpc(&r)||memcmp(&r,&saved,sizeof(r)))return 0;
  for(int i=0;i<1200;i++)if(out[i]!=123456.f)return 0;
  ac[0]=ac[24]=0;invalid_checks++;
 }
 Filter fgood={x,coef,out,mem,1200,24,1200,24,1200,24};
 for(int type=0;type<2;type++)for(unsigned k=0;k<19;k++){
  Filter r=fgood;
  switch(k){case 0:r.x=NULL;break;case 1:r.coef=NULL;break;case 2:r.out=NULL;break;case 3:r.mem=NULL;break;
   case 4:r.n=0;break;case 5:r.n=1201;break;case 6:r.order=0;break;case 7:r.order=25;break;
   case 8:r.x_cap=1199;break;case 9:r.coef_cap=23;break;case 10:r.out_cap=1199;break;case 11:r.mem_cap=23;break;
   case 12:x[1199]=NAN;break;case 13:coef[23]=INFINITY;break;case 14:mem[23]=NAN;break;
   case 15:x[0]=1e20f;break;case 16:coef[0]=1e20f;break;case 17:mem[0]=1e20f;break;case 18:r.order=-1;break;}
  Filter saved=r;float oldmem[24];memcpy(oldmem,mem,sizeof(mem));
  if((type?op_celt_iir(&r):op_celt_fir(&r))||memcmp(&r,&saved,sizeof(r))||memcmp(mem,oldmem,sizeof(mem)))return 0;
  for(int i=0;i<1200;i++)if(out[i]!=123456.f)return 0;
  x[0]=x[1199]=coef[0]=coef[23]=mem[0]=mem[23]=0;invalid_checks++;
 }
 if(op_celt_autocorr(NULL)||op_celt_lpc(NULL)||op_celt_fir(NULL)||op_celt_iir(NULL))return 0;
 invalid_checks+=4;return 1;
}
int main(void){
 const int lengths[6]={32,120,240,480,1024,2048},orders[4]={1,4,12,24};
 for(int repeat=0;repeat<8;repeat++)for(int n=0;n<6;n++)for(int p=0;p<4;p++)for(int overlap=0;overlap<2;overlap++)for(int pattern=0;pattern<8;pattern++)
  if(!trial(lengths[n],orders[p],overlap?(lengths[n]<240?lengths[n]/2:120):0,pattern))return 1;
 if(!invalid())return 1;
 printf("CELT prediction: %u windowed autocorrelations, %u LPC solves, %u FIR and %u IIR stateful/in-place frames, %llu coefficients, %u guards; max scaled error %.9g\n",ac_checks,lpc_checks,fir_checks,iir_checks,coefficients,invalid_checks,max_error);
 return 0;
}
