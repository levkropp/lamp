/* Test-only normative CELT postfilter/deemphasis comparison. */
#include "lamp-test.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include "modes.c"
#include "celt-filter-reference.inc"
typedef struct {
 float *buffer,*out;int n,history,period0,period1;float gain0,gain1;
 int tap0,tap1,overlap;unsigned buffer_cap,out_cap;
} Comb;
typedef struct {float *x,*pcm,*mem;int n,channels,downsample;unsigned x_cap,pcm_cap,mem_cap;} Deemphasis;
LAMP_ABI int op_celt_comb_filter(Comb *);
LAMP_ABI int op_celt_deemphasis(Deemphasis *);
static uint32_t rng=0xb3274825;
static uint32_t next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static unsigned comb_checks,deemphasis_checks,guards,coefficients;
static double max_error;
static int compare(const float *a,const float *b,unsigned n,float scale){
 for(unsigned i=0;i<n;i++){
  double error=fabs((double)a[i]-b[i])/scale;coefficients++;if(error>max_error)max_error=error;
  if(!isfinite(b[i])||error>.00001){printf("Output helper sample %u: %.9g/%.9g scale-adjusted error %.9g\n",i,a[i],b[i],error);return 0;}
 }return 1;
}
static int comb(int n,int T0,int T1,float g0,float g1,int tap0,int tap1,int overlap,int inplace,int pattern){
 int history=1024,cap=history+n;float a[3010],b[3010],original[3010],ya[962],yb[962];
 float scale=pattern==0?1.f:pattern==1?1e20f:1e-20f;
 for(int i=0;i<3010;i++)a[i]=b[i]=original[i]=((int)(next()%20001)-10000)*.0001f*scale;
 a[0]=b[0]=original[0]=a[cap+1]=b[cap+1]=original[cap+1]=123456.f;
 for(int i=0;i<962;i++)ya[i]=yb[i]=123456.f;
 float *outa=inplace?a+history+1:ya+1,*outb=inplace?b+history+1:yb+1;
 reference_comb(outa,a+history+1,T0,T1,n,g0,g1,tap0,tap1,mode48000_960_120.window,overlap);
 Comb request={b+1,outb,n,history,T0,T1,g0,g1,tap0,tap1,overlap,cap,n},saved=request;
 if(!op_celt_comb_filter(&request)||memcmp(&request,&saved,sizeof(saved))||b[0]!=123456.f||b[cap+1]!=123456.f||yb[0]!=123456.f||yb[n+1]!=123456.f||memcmp(b,original,(history+1)*4)||(!inplace&&memcmp(b,original,sizeof(b)))||!compare(outa,outb,n,scale)){
  printf("Comb mismatch N=%d T=%d/%d gain=%g/%g tap=%d/%d overlap=%d inplace=%d\n",n,T0,T1,g0,g1,tap0,tap1,overlap,inplace);return 0;
 }comb_checks++;return 1;
}
static int deemphasis(int n,int C,int downsample,int pattern,float *ma,float *mb){
 float x[1920],backup[1920],pa[1922],pb[1922];int count=n*C/downsample;
 float scale=pattern==0?1.f:pattern==1?1e20f:1e-20f;
 for(int i=0;i<n*C;i++)x[i]=((int)(next()%20001)-10000)*.0001f*scale;
 memcpy(backup,x,n*C*4);for(int i=0;i<1922;i++)pa[i]=pb[i]=123456.f;
 float *planes[2]={x,x+n};
 reference_deemphasis(planes,pa+1,n,C,downsample,mode48000_960_120.preemph,ma+1);
 Deemphasis request={x,pb+1,mb+1,n,C,downsample,n*C,count,C},saved=request;
 if(!op_celt_deemphasis(&request)||memcmp(&request,&saved,sizeof(saved))||memcmp(x,backup,n*C*4)||pb[0]!=123456.f||pb[count+1]!=123456.f||mb[0]!=123456.f||mb[C+1]!=123456.f||!compare(pa+1,pb+1,count,scale)||!compare(ma+1,mb+1,C,scale)){
  printf("Deemphasis mismatch N=%d C=%d downsample=%d pattern=%d\n",n,C,downsample,pattern);return 0;
 }deemphasis_checks++;return 1;
}
static int invalid(void){
 float buffer[3008],out[1920],backup[1920],mem[2]={0},pcm[1920];for(int i=0;i<3008;i++)buffer[i]=1.f;for(int i=0;i<1920;i++)out[i]=backup[i]=pcm[i]=1.f;
 Comb good={buffer,out,120,1024,1022,15,.5f,.5f,0,2,120,1144,120};
 for(unsigned t=0;t<25;t++){
  Comb request=good,saved;
  switch(t){case 0:request.buffer=NULL;break;case 1:request.out=NULL;break;case 2:request.n=0;break;case 3:request.n=961;break;
   case 4:request.history=1023;break;case 5:request.history=2049;break;case 6:request.period0=14;break;case 7:request.period0=1023;break;
   case 8:request.period1=14;break;case 9:request.period1=1023;break;case 10:request.gain0=NAN;break;case 11:request.gain1=INFINITY;break;
   case 12:request.gain0=-1.01f;break;case 13:request.gain1=1.01f;break;case 14:request.tap0=-1;break;case 15:request.tap1=3;break;
   case 16:request.overlap=-1;break;case 17:request.overlap=121;break;case 18:request.n=119;break;case 19:request.buffer_cap=1143;break;
   case 20:request.out_cap=119;break;case 21:buffer[1143]=NAN;break;case 22:buffer[0]=INFINITY;break;case 23:buffer[1143]=1e34f;break;case 24:request.period1=-1;break;
  }
  saved=request;if(op_celt_comb_filter(&request)||memcmp(&request,&saved,sizeof(saved))||memcmp(out,backup,sizeof(out))){printf("Comb guard %u failed\n",t);return 0;}
  buffer[1143]=buffer[0]=1.f;guards++;
 }
 Deemphasis dgood={buffer,pcm,mem,960,2,1,1920,1920,2};
 for(unsigned t=0;t<24;t++){
  Deemphasis request=dgood,saved;
  if(t<3)((void**)&request)[t]=NULL;
  else switch(t){case 3:request.n=0;break;case 4:request.n=119;break;case 5:request.n=1000;break;case 6:request.channels=0;break;case 7:request.channels=3;break;
   case 8:request.downsample=0;break;case 9:request.downsample=5;break;case 10:request.downsample=7;break;case 11:request.x_cap=1919;break;
   case 12:request.pcm_cap=1919;break;case 13:request.mem_cap=1;break;case 14:buffer[1919]=NAN;break;case 15:buffer[0]=INFINITY;break;
   case 16:buffer[1919]=1e38f;break;case 17:mem[1]=NAN;break;case 18:mem[0]=INFINITY;break;case 19:mem[1]=1e38f;break;
   case 20:request.channels=-1;break;case 21:request.n=-1;break;case 22:request.downsample=-1;break;case 23:request.mem_cap=0;break;
  }
  saved=request;float memory[2];memcpy(memory,mem,sizeof(mem));
  if(op_celt_deemphasis(&request)||memcmp(&request,&saved,sizeof(saved))||memcmp(pcm,backup,sizeof(pcm))||memcmp(mem,memory,sizeof(mem))){printf("Deemphasis guard %u failed\n",t);return 0;}
  buffer[1919]=buffer[0]=1.f;mem[0]=mem[1]=0;guards++;
 }
 if(op_celt_comb_filter(NULL)||op_celt_deemphasis(NULL))return 0;guards+=2;return 1;
}
int main(void){
 if(sizeof(Comb)!=64||sizeof(Deemphasis)!=48)return 2;
 if(!invalid())return 1;
 const int lengths[]={120,240,480,960},periods[]={15,16,32,511,1022},rates[]={1,2,3,4,6};
 const float gains[]={0,.09375f,.5f,.75f,1.f,-1.f};
 for(unsigned n=0;n<4;n++)for(unsigned T0=0;T0<5;T0++)for(unsigned T1=0;T1<5;T1++)for(int t0=0;t0<3;t0++)for(int t1=0;t1<3;t1++)for(unsigned g=0;g<6;g++)for(int overlap=0;overlap<=120;overlap+=120)for(int inplace=0;inplace<2;inplace++){
  if(!comb(lengths[n],periods[T0],periods[T1],gains[g],gains[(g+1)%6],t0,t1,overlap,inplace,0))return 1;
 }
 for(unsigned t=0;t<8192;t++){
  int n=1+next()%960,overlap=next()%((n<120?n:120)+1);
  if(!comb(n,15+next()%1008,15+next()%1008,((int)(next()%2001)-1000)*.001f,((int)(next()%2001)-1000)*.001f,next()%3,next()%3,overlap,next()%2,next()%3))return 1;
 }
 for(int C=1;C<=2;C++)for(int pattern=0;pattern<3;pattern++){
  float ma[4]={123456.f,0,0,123456.f},mb[4]={123456.f,0,0,123456.f};ma[C+1]=mb[C+1]=123456.f;
  for(unsigned t=0;t<4096;t++)if(!deemphasis(lengths[next()%4],C,rates[next()%5],pattern,ma,mb))return 1;
 }
 printf("Passed %u causal/separate comb filters, %u stateful deemphasis/downsample frames, %u coefficient comparisons and %u invalid guards; maximum scale-adjusted error %.9g.\n",comb_checks,deemphasis_checks,coefficients,guards,max_error);return 0;
}
