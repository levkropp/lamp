/* Development-only comparison with normative BSD RFC6716 split decoding. */
#include "lamp-test.h"
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "modes.c"
#include "bands.c"
typedef struct {
 ec_dec *ec;int *remaining;
 int n,budget,band,lm,stereo,blocks,original_blocks,intensity,fill;
 int angle,mid,side,delta,cost,invert,output_fill,qn;
} Theta;
LAMP_ABI int op_celt_theta(Theta *);
LAMP_ABI int op_celt_bitexact_cos(int);
LAMP_ABI int op_celt_log2tan(int,int);
LAMP_ABI unsigned op_celt_isqrt(unsigned);
#include "celt-theta-reference.inc"
static uint32_t seed=0x70bdfa12;
static uint32_t next(void){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;}
static unsigned theta_checks,cos_checks,log_checks,sqrt_checks,invalid_checks;
static int trial(unsigned char *data,unsigned len,int N,int budget,int band,int LM,int stereo,int B,int B0,int intensity,unsigned prime){
 ec_dec a,b;memset(&a,0,sizeof(a));memset(&b,0,sizeof(b));ec_dec_init(&a,data,len);ec_dec_init(&b,data,len);
 for(unsigned i=0;i<prime;i++){unsigned logp=1+next()%15;ec_dec_bit_logp(&a,logp);ec_dec_bit_logp(&b,logp);}
 int ra=(int)(next()%81601)-17,rb=ra,original_remaining=ra,fill=(int)next();
 struct {uint64_t before;Theta request;uint64_t after;} x={0},y={0};
 x.before=y.before=0xabcdef0123456789ULL;x.after=y.after=0x9876543210fedcbaULL;
 Theta args={&a,&ra,N,budget,band,LM,stereo,B,B0,intensity,fill};x.request=args;
 args.ec=&b;args.remaining=&rb;y.request=args;
 if(!reference_theta(&x.request)||!op_celt_theta(&y.request)||memcmp((char*)&x.request+52,(char*)&y.request+52,32)||memcmp(&a,&b,sizeof(a))||ra!=original_remaining||rb!=ra||x.before!=y.before||x.after!=y.after){
  printf("Theta mismatch len=%u N=%d b=%d band=%d LM=%d stereo=%d B=%d/%d intensity=%d angle=%d/%d qn=%d/%d tell=%d/%d\n",len,N,budget,band,LM,stereo,B,B0,intensity,x.request.angle,y.request.angle,x.request.qn,y.request.qn,ec_tell_frac(&a),ec_tell_frac(&b));
  int *p=(int*)((char*)&x.request+52),*q=(int*)((char*)&y.request+52);for(int i=0;i<8;i++)if(p[i]!=q[i])printf("scalar %d: %d/%d\n",i,p[i],q[i]);return 0;
 }
 theta_checks++;return 1;
}
static int invalid(void){
 unsigned char payload[16]={0};ec_dec ec;memset(&ec,0,sizeof(ec));ec_dec_init(&ec,payload,16);int remaining=2048;
 Theta good={&ec,&remaining,8,512,8,2,1,4,8,21,255};
 for(unsigned test=0;test<25;test++){
  Theta request=good,copy;ec_dec backup=ec,saved;
  switch(test){case 0:request.ec=NULL;break;case 1:request.remaining=NULL;break;
   case 2:request.n=1;break;case 3:request.n=1025;break;case 4:request.budget=-16385;break;case 5:request.budget=81601;break;
   case 6:request.band=-1;break;case 7:request.band=21;break;case 8:request.lm=-2;break;case 9:request.lm=4;break;
   case 10:request.stereo=2;break;case 11:request.blocks=0;break;case 12:request.blocks=3;break;case 13:request.blocks=32;break;
   case 14:request.original_blocks=0;break;case 15:request.original_blocks=3;break;case 16:request.original_blocks=32;break;
   case 17:request.intensity=-1;break;case 18:request.intensity=22;break;case 19:ec.storage=1276;break;
   case 20:ec.buf=NULL;break;case 21:ec.offs=17;break;case 22:ec.end_offs=17;break;case 23:ec.rng=0;break;case 24:ec.nend_bits=33;break;
  }
  copy=request;saved=ec;
  if(op_celt_theta(&request)||memcmp(&request,&copy,sizeof(copy))||memcmp(&ec,&saved,sizeof(ec))||remaining!=2048)return 0;
  ec=backup;invalid_checks++;
 }
 if(op_celt_theta(NULL))return 0;invalid_checks++;return 1;
}
int main(void){
 if(sizeof(Theta)!=88||offsetof(Theta,angle)!=52)return 2;
 if(!invalid()){puts("Split request guard failed");return 1;}
 for(int x=0;x<16384;x++){if(op_celt_bitexact_cos(x)!=bitexact_cos((opus_int16)x)){printf("Cosine mismatch %d\n",x);return 1;}cos_checks++;}
 for(unsigned i=0;i<131072;i++){
  int s=1+next()%32767,c=1+next()%32767;if(op_celt_log2tan(s,c)!=bitexact_log2tan(s,c)){puts("Log tangent mismatch");return 1;}log_checks++;
 }
 for(unsigned i=0;i<=65535;i++){
  unsigned square=i*i,values[3]={square,square?square-1:0,square==UINT32_MAX?square:square+1};
  for(unsigned j=0;j<3;j++){if(op_celt_isqrt(values[j])!=isqrt32(values[j])){puts("Integer square root boundary mismatch");return 1;}sqrt_checks++;}
 }
 for(unsigned i=0;i<65536;i++){unsigned x=next();if(op_celt_isqrt(x)!=isqrt32(x))return 1;sqrt_checks++;}
 const unsigned lengths[]={0,1,2,3,4,8,16,32,128,1275};
 const int sizes[]={2,3,4,8,16,22,44,88,176,352,1024};
 const int budgets[]={-17,0,8,16,17,32,33,64,128,256,512,1024,4096,81600};
 unsigned char payload[1275];
 for(unsigned kind=0;kind<3;kind++)for(unsigned l=0;l<sizeof(lengths)/sizeof(lengths[0]);l++){
  unsigned len=lengths[l];for(unsigned i=0;i<len;i++)payload[i]=kind==0?0:kind==1?255:(unsigned char)next();
  for(unsigned n=0;n<sizeof(sizes)/sizeof(sizes[0]);n++)for(unsigned b=0;b<sizeof(budgets)/sizeof(budgets[0]);b++)for(int LM=-1;LM<=3;LM++)for(int stereo=0;stereo<2;stereo++){
   if(!trial(payload,len,sizes[n],budgets[b],8,LM,stereo,1,1,21,0))return 1;
   if(!trial(payload,len,sizes[n],budgets[b],20,LM,stereo,4,8,0,8))return 1;
  }
 }
 for(unsigned t=0;t<65536;t++){
  unsigned len=next()%1276;for(unsigned i=0;i<len;i++)payload[i]=(unsigned char)next();
  if(!trial(payload,len,2+next()%1023,(int)(next()%81618)-17,next()%21,(int)(next()%5)-1,next()%2,1<<(next()%5),1<<(next()%5),next()%22,next()%16))return 1;
 }
 printf("Passed %u split-angle/entropy comparisons, %u bit-exact cosine, %u log-tangent, %u integer-square-root checks and %u invalid-request guards.\n",theta_checks,cos_checks,log_checks,sqrt_checks,invalid_checks);return 0;
}
