/* Test harness only: the RFC packet parser is generated beside this file at
   test time. No C reference code is linked into either LAMP executable. */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "lamp-test.h"
#include "opus_packet_reference.h"
#include "reference/opus-1.5.2-packet.h"
LAMP_ABI int op_opus_packet_parse(const unsigned char *,unsigned);
LAMP_ABI int op_opus_packet_parse_ex(const unsigned char *,unsigned,unsigned);
uint64_t ogg_granule,ogg_packet_page;unsigned ogg_packet_page_end;
extern const unsigned char *op_frame_ptr[48];
extern unsigned op_frame_size[48],op_frame_count,op_frame_samples,op_packet_samples,op_config,op_stereo,op_packet_bytes;
/* Unused Ogg header entry point dependencies from the same assembly module. */
uint64_t ogg_total_granule,total_frames;
unsigned sample_rate,source_channels,source_bits,decode_error;
int ogg_open(void *a,void *b){(void)a;(void)b;return 0;}
void *ogg_next(void){return 0;}
static uint32_t seed=0x98232971;
static uint32_t next(void){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;}
static unsigned checked,accepted,self_checked,self_accepted,guarded;
static int check_self(const unsigned char *p,unsigned n){
 const unsigned char *ptr[48];short sizes[48];unsigned char toc;int offset,consumed;
 int a=modern_packet_parse_impl(p,n,1,&toc,ptr,sizes,&offset,&consumed,NULL,NULL);
 int b=op_opus_packet_parse_ex(p,n,1);self_checked++;
 if((a>0)!=(b>0)||(a>0&&a!=b)){
  printf("Self packet count mismatch test=%u length=%u toc=%02x C=%d ASM=%d\n",self_checked,n,n?p[0]:0,a,b);return 0;
 }
 if(a>0){
  self_accepted++;
  if(op_packet_bytes!=consumed||op_frame_count!=a||op_frame_samples!=modern_samples_per_frame(p,48000)||op_packet_samples!=a*op_frame_samples||op_config!=(p[0]>>3)||op_stereo!=((p[0]>>2)&1)){
   printf("Self metadata mismatch test=%u consumed=%d/%u\n",self_checked,consumed,op_packet_bytes);return 0;
  }
  for(int j=0;j<a;j++)if(sizes[j]!=op_frame_size[j]||ptr[j]!=op_frame_ptr[j]){printf("Self frame mismatch test=%u frame=%d\n",self_checked,j);return 0;}
 }else if(op_packet_bytes||op_frame_count)return 0;
 return 1;
}
static int check(const unsigned char *p,unsigned n){
 const unsigned char *ptr[48];short sizes[48];unsigned char toc;int offset;
 int a=n?reference_packet_parse(p,n,&toc,ptr,sizes,&offset):-4;
 int b=op_opus_packet_parse(p,n);
 checked++;
 if((a>0)!=(b>0)|| (a>0&&a!=b)){
  printf("Packet count mismatch test=%u length=%u toc=%02x C=%d ASM=%d\n",checked,n,p[0],a,b);return 0;
 }
 if(a>0){
  accepted++;
  if(op_packet_bytes!=n||op_frame_count!=a || op_frame_samples!=reference_samples_per_frame(p,48000) ||
    op_packet_samples!=a*op_frame_samples || op_config!=(p[0]>>3)||op_stereo!=((p[0]>>2)&1))return 0;
  for(int j=0;j<a;j++)if(sizes[j]!=op_frame_size[j]||ptr[j]!=op_frame_ptr[j]){
   printf("Frame mismatch test=%u frame=%d\n",checked,j);return 0;
  }
 }
 return check_self(p,n);
}
static int guard_pages(void){
 unsigned char *memory=VirtualAlloc(NULL,12288,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);DWORD prior;
 if(!memory||!VirtualProtect(memory,4096,PAGE_NOACCESS,&prior)||!VirtualProtect(memory+8192,4096,PAGE_NOACCESS,&prior))return 0;
 for(unsigned n=0;n<=4096;n++){
  unsigned char *p=memory+8192-n;for(unsigned j=0;j<n;j++)p[j]=(unsigned char)next();
  if(!check(p,n))return 0;guarded++;
 }
 if(op_opus_packet_parse_ex(NULL,1,1)||op_opus_packet_parse_ex(memory,1,2)||op_packet_bytes||op_frame_count)return 0;
 return VirtualFree(memory,0,MEM_RELEASE)!=0;
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
 if(!guard_pages())return 1;
 printf("Passed %u regular packet framing comparisons (%u valid) and %u self-delimited comparisons (%u valid), including %u guarded boundary cases; sizes, pointers, duration and consumed bytes including padding.\n",checked,accepted,self_checked,self_accepted,guarded);return 0;
}
