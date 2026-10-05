/* Test-only normative fixed-point division and analysis/rewhitening. */
#include "lamp-test.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "main.h"
typedef struct {int16_t *out;const int16_t *in,*coef;int n,order;unsigned out_cap,in_cap,coef_cap;} Analysis;
LAMP_ABI int op_silk_div32(int,int,int);
LAMP_ABI int op_silk_analysis_filter(Analysis *);
static uint32_t rng=0x54c18eb2;
static uint32_t next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static unsigned division_checks,filter_checks,guards;
static unsigned long long samples;
static int divide(int a,int b,int q){
 int x=silk_DIV32_varQ(a,b,q),y=op_silk_div32(a,b,q);
 if(x!=y){printf("Division a=%d b=%d q=%d %d/%d\n",a,b,q,x,y);return 0;}
 division_checks++;return 1;
}
static int division(void){
 const int edge[]={-2147483647,-1073741824,-65537,-65536,-65535,-32769,-32768,-32767,-2,-1,0,1,2,32767,32768,32769,65535,65536,65537,1073741824,2147483647};
 for(int q=0;q<=30;q++){
  for(unsigned i=0;i<sizeof(edge)/sizeof(*edge);i++)for(unsigned j=0;j<sizeof(edge)/sizeof(*edge);j++)if(edge[j]&&!divide(edge[i],edge[j],q))return 0;
  for(unsigned i=0;i<16384;i++){
   int a=(int)next(),b=(int)next();if(a==INT32_MIN)a=INT32_MAX;if(!b||b==INT32_MIN)b=-1;
   if(!divide(a,b,q))return 0;
  }
 }
 return 1;
}
static int filter(int order,int n,unsigned pattern){
 int16_t a[482],b[482],in[480],coef[16],saved_in[480],saved_coef[16];
 for(unsigned i=0;i<482;i++)a[i]=b[i]=-12345;
 memset(in,0xa5,sizeof(in));memset(coef,0xa5,sizeof(coef));
 for(int i=0;i<n;i++)in[i]=(int16_t)(pattern%6==0?0:pattern%6==1?INT16_MAX:pattern%6==2?INT16_MIN:pattern%6==3?(i%2?INT16_MIN:INT16_MAX):next());
 for(int i=0;i<order;i++)coef[i]=(int16_t)(pattern%6==0?0:pattern%6==1?INT16_MAX:pattern%6==2?INT16_MIN:next());
 memcpy(saved_in,in,sizeof(in));memcpy(saved_coef,coef,sizeof(coef));
 silk_LPC_analysis_filter(a+1,in,coef,n,order);
 Analysis request={b+1,in,coef,n,order,n,n,order},saved=request;
 if(!op_silk_analysis_filter(&request)||memcmp(a,b,sizeof(a))||memcmp(in,saved_in,sizeof(in))||memcmp(coef,saved_coef,sizeof(coef))||memcmp(&request,&saved,sizeof(request))){printf("Analysis order=%d n=%d pattern=%u\n",order,n,pattern);return 0;}
 filter_checks++;samples+=n;return 1;
}
static int filters(void){
 for(int order=6;order<=16;order+=2)for(unsigned i=0;i<4096;i++){
  int n=i%5==0?order:i%5==1?480:i%5==2?order+1:order+next()%(481-order);
  if(!filter(order,n,i))return 0;
 }
 return 1;
}
static int invalid(void){
 int16_t in[480]={0},coef[16]={0},out[480];memset(out,0xa5,sizeof(out));
 Analysis base={out,in,coef,480,16,480,480,16};
 for(unsigned i=0;i<13;i++){
  Analysis r=base;switch(i){case 0:r.out=NULL;break;case 1:r.in=NULL;break;case 2:r.coef=NULL;break;case 3:r.n=15;break;case 4:r.n=481;break;case 5:r.order=5;break;case 6:r.order=18;break;case 7:r.order=15;break;case 8:r.out_cap=479;break;case 9:r.in_cap=479;break;case 10:r.coef_cap=15;break;case 11:r.n=-1;break;case 12:r.order=-1;break;}
  Analysis saved=r;int16_t prior[480];memcpy(prior,out,sizeof(out));
  if(op_silk_analysis_filter(&r)||memcmp(&r,&saved,sizeof(r))||memcmp(out,prior,sizeof(out)))return 0;guards++;
 }
 if(op_silk_analysis_filter(NULL)||op_silk_div32(1,0,16)||op_silk_div32(INT32_MIN,1,16)||op_silk_div32(1,INT32_MIN,16)||op_silk_div32(1,1,-1)||op_silk_div32(1,1,31))return 0;guards+=6;return 1;
}
int main(void){
 if(!division()||!filters()||!invalid())return 1;
 printf("SILK prediction: %u exact fixed-point divisions, %u zero-state LPC analysis/rewhitening filters, %llu int16 samples, %u guards\n",division_checks,filter_checks,samples,guards);
 return 0;
}
