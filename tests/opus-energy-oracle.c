/* Test-only comparisons with RFC6716's floating-point energy reconstruction. */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "quant_bands.c"
int op_laplace_decode(ec_dec *,unsigned,int);
typedef struct Energy {
 ec_dec *ec;float *old;int *fine,*priority;
 int start,end,channels,lm,intra,bits_left,bands;
} Energy;
void op_celt_coarse(Energy *);
void op_celt_fine(Energy *);
void op_celt_final(Energy *);
static unsigned seed=0x84789451;
static unsigned next(void){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;}
static int compare(unsigned vector,const char *stage,float *a,float *b,ec_dec *c,ec_dec *d){
 if(memcmp(c,d,sizeof(*c))){printf("Entropy mismatch %u %s\n",vector,stage);return 0;}
 for(unsigned i=0;i<42;i++)if(a[i]!=b[i]){
  printf("Energy mismatch %u %s band=%u C=%g ASM=%g\n",vector,stage,i,a[i],b[i]);return 0;
 }
 return 1;
}
int main(void){
 unsigned char data[256];unsigned laplace=0,energy=0;
 for(unsigned vector=0;vector<4096;vector++){
  unsigned len=next()%257;for(unsigned i=0;i<len;i++)data[i]=(unsigned char)next();
  ec_dec a,b;memset(&a,0,sizeof(a));memset(&b,0,sizeof(b));ec_dec_init(&a,data,len);ec_dec_init(&b,data,len);
  for(unsigned i=0;i<32;i++){
   unsigned fs=1+next()%32735,decay=next()%16384;
   int x=ec_laplace_decode(&a,fs,decay),y=op_laplace_decode(&b,fs,decay);
   if(x!=y||memcmp(&a,&b,sizeof(a))){printf("Laplace mismatch %u symbol=%u fs=%u decay=%u\n",vector,i,fs,decay);return 1;}
   laplace++;
  }
  ec_dec_init(&a,data,len);ec_dec_init(&b,data,len);
  float ea[42],eb[42];int fine[21],priority[21];
  for(unsigned i=0;i<42;i++)ea[i]=eb[i]=((int)(next()%6000)-3000)*0.01f;
  for(unsigned i=0;i<21;i++){fine[i]=next()%9;priority[i]=next()%2;}
  CELTMode mode;memset(&mode,0,sizeof(mode));mode.nbEBands=21;
  Energy e={&b,eb,fine,priority,next()%21,0,1+(vector%2),(vector>>1)%4,(vector>>3)%2,next()%43,21};
  e.end=e.start+next()%(22-e.start);
  unquant_coarse_energy(&mode,e.start,e.end,ea,e.intra,&a,e.channels,e.lm);op_celt_coarse(&e);
  if(!compare(vector,"coarse",ea,eb,&a,&b))return 1;energy++;
  unquant_fine_energy(&mode,e.start,e.end,ea,fine,&a,e.channels);op_celt_fine(&e);
  if(!compare(vector,"fine",ea,eb,&a,&b))return 1;energy++;
  unquant_energy_finalise(&mode,e.start,e.end,ea,fine,priority,e.bits_left,&a,e.channels);op_celt_final(&e);
  if(!compare(vector,"final",ea,eb,&a,&b))return 1;energy++;
 }
 printf("Passed %u exact Laplace symbols and %u energy-stage comparisons.\n",laplace,energy);return 0;
}
