/* Test-only RFC6716 oracle. The assembly player does not compile or call C. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "entdec.h"
void op_ec_init(ec_dec *,unsigned char *,unsigned);
unsigned op_ec_decode(ec_dec *,unsigned);
unsigned op_ec_bin(ec_dec *,unsigned);
void op_ec_update(ec_dec *,unsigned,unsigned,unsigned);
int op_ec_logp(ec_dec *,unsigned);
int op_ec_icdf(ec_dec *,const unsigned char *,unsigned);
unsigned op_ec_bits(ec_dec *,unsigned);
unsigned op_ec_uint(ec_dec *,unsigned);
unsigned op_ec_tell(ec_dec *);
unsigned op_ec_frac(ec_dec *);
static unsigned random_state=0x642f9a32;
static unsigned next(void){random_state^=random_state<<13;random_state^=random_state>>17;random_state^=random_state<<5;return random_state;}
int main(void){
 unsigned char data[1275],icdf[16];unsigned operations=0;
 for(unsigned vector=0;vector<4096;vector++){
  unsigned len=next()%1276;for(unsigned i=0;i<len;i++)data[i]=(unsigned char)next();
  ec_dec a,b;memset(&a,0,sizeof(a));memset(&b,0,sizeof(b));ec_dec_init(&a,data,len);op_ec_init(&b,data,len);
  for(unsigned i=0;i<128;i++){
   unsigned type=next()%6, arg=next(),x,y;
   switch(type){
    case 0: arg=2+(arg%65534);x=ec_dec_uint(&a,arg);y=op_ec_uint(&b,arg);break;
    case 1: arg=1+(arg%15);x=ec_dec_bit_logp(&a,arg);y=op_ec_logp(&b,arg);break;
    case 2: arg=arg%26;x=ec_dec_bits(&a,arg);y=op_ec_bits(&b,arg);break;
    case 3: for(unsigned j=0;j<16;j++)icdf[j]=(unsigned char)(240-16*j);x=ec_dec_icdf(&a,icdf,8);y=op_ec_icdf(&b,icdf,8);break;
    case 4: arg=1+(arg%15);x=ec_decode_bin(&a,arg);y=op_ec_bin(&b,arg);ec_dec_update(&a,x,x+1,1U<<arg);op_ec_update(&b,y,y+1,1U<<arg);break;
    default: arg=2+(arg%65534);x=ec_decode(&a,arg);y=op_ec_decode(&b,arg);ec_dec_update(&a,x,x+1,arg);op_ec_update(&b,y,y+1,arg);break;
   }
   if(x!=y || memcmp(&a,&b,sizeof(a)) || ec_tell(&a)!=op_ec_tell(&b) || ec_tell_frac(&a)!=op_ec_frac(&b)){
    printf("Mismatch vector=%u operation=%u type=%u arg=%u symbols=%u/%u\n",vector,i,type,arg,x,y);return 1;
   }
   operations++;
  }
 }
 printf("Passed %u exact Opus range operations and state/tell comparisons.\n",operations);return 0;
}
