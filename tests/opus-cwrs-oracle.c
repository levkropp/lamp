/* Test-only comparison with the normative CELT signed-pulse enumeration. */
#include "lamp-test.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#define SMALL_FOOTPRINT
#include "cwrs.c"
LAMP_ABI unsigned op_cwrs_urow(unsigned,unsigned,unsigned *);
LAMP_ABI void op_cwrs_decode(unsigned,unsigned,unsigned,int *,unsigned *);
LAMP_ABI int op_decode_pulses(int *,unsigned,unsigned,ec_dec *);
static unsigned seed=0x14257492;
static unsigned next(void){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;}
static unsigned checks;
static int test(unsigned n,unsigned k){
 unsigned a[32769],b[32769];int x[1024],y[1024];
 unsigned count=ncwrs_urow(n,k,a),asm_count=op_cwrs_urow(n,k,b);
 if(count!=asm_count||memcmp(a,b,(k+2)*sizeof(unsigned)))return 0;
 for(unsigned j=0;j<20;j++){
  unsigned idx=j==0?0:j==1?count-1:next()%count;
  ncwrs_urow(n,k,a);op_cwrs_urow(n,k,b);
  cwrsi(n,k,idx,x,a);op_cwrs_decode(n,k,idx,y,b);
  unsigned sum=0;for(unsigned q=0;q<n;q++)sum+=abs(y[q]);
  if(sum!=k||memcmp(x,y,n*sizeof(int))||memcmp(a,b,(k+2)*sizeof(unsigned)))return 0;
  checks++;
 }
 unsigned char data[64];for(unsigned j=0;j<64;j++)data[j]=(unsigned char)next();
 ec_dec c,d;memset(&c,0,sizeof(c));memset(&d,0,sizeof(d));ec_dec_init(&c,data,64);ec_dec_init(&d,data,64);
 decode_pulses(x,n,k,&c);
 if(!op_decode_pulses(y,n,k,&d)||memcmp(x,y,n*sizeof(int))||memcmp(&c,&d,sizeof(c)))return 0;
 checks++;
 return 1;
}
int main(void){
 /* Determine legal U/V values in 64-bit arithmetic; saturation avoids wrap. */
 uint64_t u[130]={0},v[130];
 for(unsigned k=1;k<130;k++)u[k]=1;
 for(unsigned n=2;n<=1024;n++){
  v[0]=0;
  for(unsigned k=1;k<130;k++){
   uint64_t t=u[k]+u[k-1]+v[k-1];v[k]=t>0x100000000ULL?0x100000000ULL:t;
  }
  memcpy(u,v,sizeof(u));
  for(unsigned k=1;k<=128;k++){
   if(u[k]+u[k+1]>0xffffffffULL)break;
   if(!test(n,k)){printf("Pulse mismatch N=%u K=%u\n",n,k);return 1;}
  }
 }
 /* Long legal two-dimensional pulse vectors exercise the upper scratch bound. */
 for(unsigned k=256;k<=32767;k=k*2+1)if(!test(2,k))return 1;
 if(!test(2,32767))return 1;
 printf("Passed %u signed-pulse enumeration and entropy comparisons.\n",checks);return 0;
}
