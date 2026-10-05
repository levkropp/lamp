/* Original test-only harness: guarded output, sticky cancellation and close. */
#include "lamp-test.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
LAMP_ABI int decoder_open(const lamp_char *);
LAMP_ABI void decoder_close(void);
LAMP_ABI unsigned decoder_read(float *,unsigned);
LAMP_ABI uint64_t decoder_seek(uint64_t);
extern uint64_t total_frames;
extern unsigned decode_error,source_channels,source_bits;
extern unsigned *ogg_cancel_ptr;
static SIZE_T committed(void){PROCESS_MEMORY_COUNTERS_EX p={0};p.cb=sizeof(p);return GetProcessMemoryInfo(GetCurrentProcess(),(PROCESS_MEMORY_COUNTERS *)&p,sizeof(p))?p.PrivateUsage:0;}
static int failed(unsigned line){fprintf(stderr,"PCM bounds assertion at line %u\n",line);return 1;}
int lamp_main(int argc,lamp_char **argv){
 if(argc!=3)return 2;
 FILE *f=lamp_fopen(argv[2],LT("rb"));if(!f||fseek(f,0,SEEK_END))return 2;
 long bytes=ftell(f);if(bytes<0||bytes%8)return 2;rewind(f);
 unsigned char *expected=malloc(bytes?bytes:1);if(!expected||fread(expected,1,bytes,f)!=(size_t)bytes)return 2;fclose(f);
 SYSTEM_INFO info;GetSystemInfo(&info);SIZE_T page=info.dwPageSize;
 if(page<4096)return 2;unsigned char *region=VirtualAlloc(NULL,6*page,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);DWORD old;
 if(!region||!VirtualProtect(region,page,PAGE_NOACCESS,&old)||!VirtualProtect(region+5*page,page,PAGE_NOACCESS,&old))return 2;
 if(!decoder_open(argv[1]))return failed(__LINE__);unsigned channels=source_channels,bits=source_bits,reads=0,at=0;
 unsigned empty_seeks=0;if(!bytes){if(total_frames)return failed(__LINE__);const uint64_t requests[]={0,1,UINT64_MAX};for(unsigned i=0;i<3;i++){if(decoder_seek(requests[i])||decode_error)return failed(__LINE__);empty_seeks++;}}
 const unsigned sizes[]={0,1,2,17,257,960,2048,31,511};
 while(at<(unsigned)bytes){
  unsigned cap=sizes[reads%9],n,wanted=((unsigned)bytes-at)/8;if(wanted>cap)wanted=cap;
  unsigned char *out=region+5*page-cap*8;memset(out,0xa5,cap*8);
  n=decoder_read((float *)out,cap);
  if(n!=wanted||decode_error||memcmp(out,expected+at,n*8))return failed(__LINE__);
  for(unsigned i=n*8;i<cap*8;i++)if(out[i]!=0xa5)return failed(__LINE__);
  at+=n*8;reads++;
 }
 if(decoder_read((float *)(region+5*page),0)||decoder_read((float *)(region+5*page-8),1)||decode_error)return failed(__LINE__);
 decoder_close();if(decoder_read((float *)(region+5*page),1))return failed(__LINE__);
 unsigned cancel=1;ogg_cancel_ptr=&cancel;
 if(decoder_open(argv[1])||!decode_error)return failed(__LINE__);decoder_close();ogg_cancel_ptr=NULL;
 if(!decoder_open(argv[1]))return failed(__LINE__);ogg_cancel_ptr=&cancel;
 if(decoder_read((float *)(region+5*page),1)||!decode_error)return failed(__LINE__);
 ogg_cancel_ptr=NULL;if(decoder_read((float *)(region+5*page),1)||!decode_error)return failed(__LINE__);decoder_close();
 if(!decoder_open(argv[1])||decoder_read((float *)(region+5*page-8),1)!=(bytes?1U:0U)||decode_error)return failed(__LINE__);
 ogg_cancel_ptr=&cancel;if(decoder_read((float *)(region+5*page),1)||!decode_error)return failed(__LINE__);ogg_cancel_ptr=NULL;decoder_close();
 // Warm allocator/process accounting, then repeated opens must release the
 // bounded extra-channel allocation. Allow one OS page of accounting noise.
 for(unsigned i=0;i<8;i++){if(!decoder_open(argv[1]))return failed(__LINE__);decoder_close();}
 SIZE_T before=committed();if(!before)return 2;
 for(unsigned i=0;i<64;i++){if(!decoder_open(argv[1]))return failed(__LINE__);decoder_close();}
 SIZE_T after=committed();if(after>before+page)return failed(__LINE__);
 VirtualFree(region,0,MEM_RELEASE);free(expected);
 printf("{\"result\":\"passed\",\"channels\":%u,\"depth\":%u,\"guarded_reads\":%u,\"empty_seeks\":%u,\"cancel_checks\":4,\"reopen_checks\":64,\"private_bytes_before\":%llu,\"private_bytes_after\":%llu}\n",channels,bits,reads,empty_seeks,(unsigned long long)before,(unsigned long long)after);return 0;
}
