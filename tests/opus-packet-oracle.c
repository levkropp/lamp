/* Test harness only: the RFC packet parser is generated beside this file at
   test time. No C reference code is linked into either LAMP executable. */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "opus_packet_reference.h"
int opus_packet_parse(const unsigned char *,unsigned);
extern const unsigned char *op_frame_ptr[48];
extern unsigned op_frame_size[48],op_frame_count,op_frame_samples,op_packet_samples,op_config,op_stereo;
/* Unused Ogg header entry point dependencies from the same assembly module. */
uint64_t ogg_total_granule,total_frames;
unsigned sample_rate,source_channels,source_bits,decode_error;
int ogg_open(void *a,void *b){(void)a;(void)b;return 0;}
void *ogg_next(void){return 0;}
static uint32_t seed=0x98232971;
static uint32_t next(void){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;}
static unsigned checked,accepted;
static int check(const unsigned char *p,unsigned n){
 const unsigned char *ptr[48];short sizes[48];unsigned char toc;int offset;
 int a=n?reference_packet_parse(p,n,&toc,ptr,sizes,&offset):-4;
 int b=opus_packet_parse(p,n);
 checked++;
 if((a>0)!=(b>0)|| (a>0&&a!=b)){
  printf("Packet count mismatch test=%u length=%u toc=%02x C=%d ASM=%d\n",checked,n,p[0],a,b);return 0;
 }
 if(a>0){
  accepted++;
  if(op_frame_count!=a || op_frame_samples!=reference_samples_per_frame(p,48000) ||
    op_packet_samples!=a*op_frame_samples || op_config!=(p[0]>>3)||op_stereo!=((p[0]>>2)&1))return 0;
  for(int j=0;j<a;j++)if(sizes[j]!=op_frame_size[j]||ptr[j]!=op_frame_ptr[j]){
   printf("Frame mismatch test=%u frame=%d\n",checked,j);return 0;
  }
 }
 return 1;
}
int main(void){
 unsigned char data[65536]={0};
 /* Every TOC, all framing codes, empty/maximum frames, and count/padding bits. */
 for(unsigned toc=0;toc<256;toc++){
  data[0]=(unsigned char)toc;
  for(unsigned n=0;n<12;n++)for(unsigned ch=0;ch<256;ch++){
   data[1]=(unsigned char)ch;data[2]=252;data[3]=255;
   if(!check(data,n))return 1;
  }
  for(unsigned n=1270;n<2560;n++){data[1]=1;data[2]=0;if(!check(data,n))return 1;}
 }
 /* Seeded malformed and valid random packets, including padding chains. */
 for(unsigned i=0;i<100000;i++){
  unsigned n=next()%4096;
  for(unsigned j=0;j<n;j++)data[j]=(unsigned char)next();
  if(!check(data,n))return 1;
 }
 printf("Passed %u packet framing comparisons (%u valid packets).\n",checked,accepted);return 0;
}
