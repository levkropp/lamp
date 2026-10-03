/* Development-only comparison with BSD normative RFC6716 allocation. */
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "modes.c"
#include "rate.c"
typedef struct {
 ec_dec *ec;
 const int *offsets,*caps;
 int *bits,*fine,*priority;
 int start,end,channels,lm,trim,total;
 int intensity,dual,balance,coded;
} Allocation;
int op_celt_allocate(Allocation *);
int op_celt_init_caps(int *,int,int);
int op_celt_bits2pulses(int,int,int);
int op_celt_pulses2bits(int,int,int);
static uint32_t seed=0x58269314;
static uint32_t next(void){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;}
static unsigned checks,cache_checks,invalid_checks;
static const CELTMode *m=&mode48000_960_120;
static void caps(int *x,int C,int LM){
 for(int i=0;i<21;i++)x[i]=(m->cache.caps[21*(2*LM+C-1)+i]+64)*C*((m->eBands[i+1]-m->eBands[i])<<LM)>>2;
}
static int trial(int C,int LM,int start,int end,int trim,int budget,int boost){
 unsigned char payload[1275];int offsets[21],cap[21],asmcap[21],p[21],q[21],f[21],g[21],h[21],j[21];
 for(int i=0;i<1275;i++)payload[i]=(unsigned char)next();
 for(int i=0;i<21;i++){offsets[i]=boost&&next()%4==0?(int)(next()%256):0;p[i]=q[i]=f[i]=g[i]=h[i]=j[i]=-1234567;}
 caps(cap,C,LM);if(!op_celt_init_caps(asmcap,C,LM)||memcmp(cap,asmcap,sizeof(cap)))return 0;
 ec_dec a,b;memset(&a,0,sizeof(a));memset(&b,0,sizeof(b));
 ec_dec_init(&a,payload,1275);ec_dec_init(&b,payload,1275);
 /* Exercise noninitial entropy states as encountered after packet flags/energy. */
 for(int i=0;i<8;i++){unsigned logp=next()%12+1;if(ec_dec_bit_logp(&a,logp)!=ec_dec_bit_logp(&b,logp))return 0;}
 int intensity=-1,dual=-1,balance=-1;
 int coded=compute_allocation(m,start,end,offsets,cap,trim,&intensity,&dual,budget,&balance,p,f,h,C,LM,&a,0,0);
 Allocation request={&b,offsets,cap,q,g,j,start,end,C,LM,trim,budget,-1,-1,-1,-1};
 int actual=op_celt_allocate(&request);
 if(coded!=actual||intensity!=request.intensity||dual!=request.dual||balance!=request.balance||
    coded!=request.coded||memcmp(p,q,sizeof(p))||memcmp(f,g,sizeof(f))||memcmp(h,j,sizeof(h))||memcmp(&a,&b,sizeof(a))){
  printf("Allocation mismatch C=%d LM=%d start=%d end=%d trim=%d total=%d boost=%d coded=%d/%d intensity=%d/%d dual=%d/%d balance=%d/%d\n",C,LM,start,end,trim,budget,boost,coded,actual,intensity,request.intensity,dual,request.dual,balance,request.balance);
  for(int i=start;i<end;i++)if(p[i]!=q[i]||f[i]!=g[i]||h[i]!=j[i])printf("band %d bits %d/%d fine %d/%d priority %d/%d\n",i,p[i],q[i],f[i],g[i],h[i],j[i]);
  return 0;
 }
 checks++;return 1;
}
static int invalid(void){
 unsigned char data[16]={0};ec_dec ec,saved;memset(&ec,0,sizeof(ec));ec_dec_init(&ec,data,16);
 int array[21],backup[21];memset(array,0,sizeof(array));memcpy(backup,array,sizeof(array));
 Allocation good={&ec,array,array,array,array,array,0,21,2,3,5,1024,91,92,93,94};
 for(int k=0;k<18;k++){
  Allocation x=good,copy;
  switch(k){case 0:x.ec=0;break;case 1:x.offsets=0;break;case 2:x.caps=0;break;case 3:x.bits=0;break;case 4:x.fine=0;break;case 5:x.priority=0;break;
   case 6:x.start=-1;break;case 7:x.end=22;break;case 8:x.end=0;break;case 9:x.channels=0;break;case 10:x.channels=3;break;case 11:x.lm=4;break;case 12:x.lm=-1;break;case 13:x.trim=11;break;case 14:x.total=81601;break;case 15:array[0]=-1;break;case 16:array[0]=65537;break;case 17:x.trim=-1;break;}
  copy=x;saved=ec;memcpy(backup,array,sizeof(array));
  if(op_celt_allocate(&x)!=-1||memcmp(&x,&copy,sizeof(x))||memcmp(&ec,&saved,sizeof(ec))||memcmp(array,backup,sizeof(array)))return 0;
  array[0]=0;invalid_checks++;
 }
 if(op_celt_allocate(0)!=-1)return 0;invalid_checks++;
 if(op_celt_init_caps(0,1,0)||op_celt_init_caps(array,0,0)||op_celt_init_caps(array,1,4))return 0;
 invalid_checks+=3;
 const int bad_rate[][3]={{-1,0,8},{21,0,8},{0,-2,8},{0,4,8},{0,0,-1},{0,0,81601}};
 for(unsigned i=0;i<sizeof(bad_rate)/sizeof(bad_rate[0]);i++){if(op_celt_bits2pulses(bad_rate[i][0],bad_rate[i][1],bad_rate[i][2])!=-1)return 0;invalid_checks++;}
 const int bad_cost[][3]={{-1,0,0},{21,0,0},{0,-2,0},{0,4,0},{0,0,41}};
 for(unsigned i=0;i<sizeof(bad_cost)/sizeof(bad_cost[0]);i++){if(op_celt_pulses2bits(bad_cost[i][0],bad_cost[i][1],bad_cost[i][2])!=-1)return 0;invalid_checks++;}
 return 1;
}
int main(void){
 if(sizeof(Allocation)!=88||offsetof(Allocation,start)!=48)return 2;
 if(!invalid()){puts("Invalid request guard mismatch");return 1;}
 for(int LM=-1;LM<=3;LM++)for(int band=0;band<21;band++){
  const int index=m->cache.index[(LM+1)*21+band];
  if(index<0){if(op_celt_bits2pulses(band,LM,8)!=-1||op_celt_pulses2bits(band,LM,0)!=-1)return 1;continue;}
  const unsigned char *cache=m->cache.bits+index;
  for(int bits=0;bits<=512;bits++){if(bits2pulses(m,band,LM,bits)!=op_celt_bits2pulses(band,LM,bits)){printf("Cache mismatch LM=%d band=%d bits=%d\n",LM,band,bits);return 1;}cache_checks++;}
  for(int pseudo=0;pseudo<=cache[0];pseudo++){if(pulses2bits(m,band,LM,pseudo)!=op_celt_pulses2bits(band,LM,pseudo))return 1;cache_checks++;}
 }
 for(int C=1;C<=2;C++)for(int LM=0;LM<=3;LM++)for(int trim=0;trim<=10;trim++)for(int end=1;end<=21;end++)for(int b=0;b<=128;b++){
  int budget=b==0?-17:b<=64?b-1:(b-64)*128;
  if(!trial(C,LM,0,end,trim,budget,b&1))return 1;
 }
 for(unsigned i=0;i<32768;i++){
  int start=next()%21,end=start+1+next()%(21-start);
  if(!trial(1+next()%2,next()%4,start,end,next()%11,next()%81601,next()%2))return 1;
 }
 printf("Passed %u allocation/entropy comparisons, %u pulse-cache comparisons, %u invalid-request guards.\n",checks,cache_checks,invalid_checks);return 0;
}
