/* Test-only reference comparison for SILK shell and excitation decoding. */
#include "lamp-test.h"
#include <stdio.h>
#include <string.h>
#include "main.h"
LAMP_ABI void op_silk_shell(int *,ec_dec *,unsigned);
LAMP_ABI int op_silk_pulses(ec_dec *,int *,unsigned,unsigned,unsigned);
static unsigned seed=0x12948231;
static unsigned next(void){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;}
int main(void){
 unsigned char data[256];int x[320],y[320];unsigned shell=0,pulses=0;
 unsigned lengths[]={80,120,160,240,320};
 for(unsigned vector=0;vector<4096;vector++){
  unsigned len=next()%257;for(unsigned i=0;i<len;i++)data[i]=(unsigned char)next();
  ec_dec a,b;memset(&a,0,sizeof(a));memset(&b,0,sizeof(b));
  for(unsigned sum=0;sum<=16;sum++){
   ec_dec_init(&a,data,len);ec_dec_init(&b,data,len);
   silk_shell_decoder(x,&a,sum);op_silk_shell(y,&b,sum);
   if(memcmp(x,y,16*sizeof(int))||memcmp(&a,&b,sizeof(a))){printf("Shell mismatch vector=%u sum=%u\n",vector,sum);return 1;}
   shell++;
  }
  for(unsigned signal=0;signal<3;signal++)for(unsigned offset=0;offset<2;offset++){
   unsigned length=lengths[(vector+signal+offset)%5],padded=(length+15)&~15;
   ec_dec_init(&a,data,len);ec_dec_init(&b,data,len);
   silk_decode_pulses(&a,x,signal,offset,length);
   if(!op_silk_pulses(&b,y,signal,offset,length)||memcmp(x,y,padded*sizeof(int))||memcmp(&a,&b,sizeof(a))){
    printf("Excitation mismatch vector=%u signal=%u offset=%u length=%u\n",vector,signal,offset,length);return 1;
   }
   pulses++;
  }
 }
 printf("Passed %u SILK shell trees and %u excitation/state comparisons.\n",shell,pulses);return 0;
}
