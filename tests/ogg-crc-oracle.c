/* Independent bit-at-a-time Ogg CRC oracle; mapped end has a guard page. */
#include "lamp-test.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
unsigned decode_error;
LAMP_ABI int ogg_open(const unsigned char *,const unsigned char *);
LAMP_ABI void ogg_close(void);
static uint32_t crc(const unsigned char *data,unsigned bytes){uint32_t value=0;for(unsigned i=0;i<bytes;i++){value^=(uint32_t)(i>=22&&i<26?0:data[i])<<24;for(unsigned j=0;j<8;j++)value=(value<<1)^((value&0x80000000)?0x04c11db7:0);}return value;}
static void u32(unsigned char *p,uint32_t value){for(unsigned j=0;j<4;j++)p[j]=(unsigned char)(value>>(8*j));}
static unsigned page(unsigned char *p,unsigned length,unsigned sequence,unsigned flags,unsigned *random){
 unsigned count=length/255+1,bytes=27+count+length;memset(p,0,27+count);memcpy(p,"OggS",4);p[5]=(unsigned char)flags;p[6]=(unsigned char)(sequence?123:0);u32(p+14,0x504d414c);u32(p+18,sequence);p[26]=(unsigned char)count;
 for(unsigned j=0;j<count;j++)p[27+j]=(unsigned char)(j+1<count?255:length%255);
 for(unsigned j=27+count;j<bytes;j++){*random=*random*1664525+1013904223;p[j]=(unsigned char)(*random>>24);}u32(p+22,crc(p,bytes));return bytes;
}
int main(void){
 unsigned char *allocation=VirtualAlloc(NULL,131072,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);if(!allocation)return 2;DWORD old;
 unsigned char *end=allocation+126976;if(!VirtualProtect(end,4096,PAGE_NOACCESS,&old))return 2;
 unsigned char file[65536];unsigned random=0x17593,passed=0,rejected=0;uint64_t reference_bytes=0;
 for(unsigned trial=0;trial<4096;trial++){
  unsigned length;if(trial<1025)length=trial;else if(trial<1281)length=65024-(trial-1025);else{random=random*1664525+1013904223;length=random%65025;}
  unsigned header=page(file,7,0,2,&random),last=page(file+header,length,1,4,&random),bytes=header+last;reference_bytes+=bytes;
  unsigned char *begin=end-bytes;memcpy(begin,file,bytes);decode_error=0;
  if(!ogg_open(begin,end)||decode_error){fprintf(stderr,"Ogg CRC valid case%u length%u rejected: %u\n",trial,length,decode_error);return 1;}ogg_close();passed++;
  /* Every checksum field byte is excluded during CRC computation, then the
     resulting32-bit value is compared; a changed field must still reject. */
  begin[header+22+trial%4]^=1;decode_error=0;
  if(ogg_open(begin,end)||decode_error!=21){fprintf(stderr,"Ogg CRC changed checksum accepted\n");return 1;}ogg_close();rejected++;memcpy(begin,file,bytes);
  if(length){unsigned body=header+27+file[header+26],offset=trial%3==0?0:trial%3==1?length/2:length-1;begin[body+offset]^=1;decode_error=0;if(ogg_open(begin,end)||decode_error!=21)return 1;ogg_close();rejected++;}
 }
 VirtualFree(allocation,0,MEM_RELEASE);printf("{\"result\":\"passed\",\"valid_streams\":%u,\"rejected_crc_mutations\":%u,\"reference_bytes\":%llu,\"guarded_mapped_end\":true,\"scope\":\"Independent bitwise CRC; all body lengths0..1024,maximum page sizes,random lengths/alignments,checksum-field exclusion,payload corruption and no overread past mapped end\"}\n",passed,rejected,reference_bytes);return 0;
}
