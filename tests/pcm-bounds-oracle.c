/* Original test-only harness: guarded output, sticky cancellation and close. */
#include <windows.h>
#include <psapi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int decoder_open(const wchar_t *);
void decoder_close(void);
unsigned decoder_read(float *,unsigned);
extern unsigned decode_error,source_channels,source_bits;
extern unsigned *ogg_cancel_ptr;
static SIZE_T committed(void){PROCESS_MEMORY_COUNTERS_EX p={0};p.cb=sizeof(p);return GetProcessMemoryInfo(GetCurrentProcess(),(PROCESS_MEMORY_COUNTERS *)&p,sizeof(p))?p.PrivateUsage:0;}
int wmain(int argc,wchar_t **argv){
 if(argc!=3)return 2;
 FILE *f=_wfopen(argv[2],L"rb");if(!f||fseek(f,0,SEEK_END))return 2;
 long bytes=ftell(f);if(bytes<=0||bytes%8)return 2;rewind(f);
 unsigned char *expected=malloc(bytes);if(!expected||fread(expected,1,bytes,f)!=(size_t)bytes)return 2;fclose(f);
 SYSTEM_INFO info;GetSystemInfo(&info);SIZE_T page=info.dwPageSize;
 if(page<4096)return 2;unsigned char *region=VirtualAlloc(NULL,6*page,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);DWORD old;
 if(!region||!VirtualProtect(region,page,PAGE_NOACCESS,&old)||!VirtualProtect(region+5*page,page,PAGE_NOACCESS,&old))return 2;
 if(!decoder_open(argv[1]))return 1;unsigned channels=source_channels,bits=source_bits,reads=0,at=0;
 const unsigned sizes[]={0,1,2,17,257,960,2048,31,511};
 while(at<(unsigned)bytes){
  unsigned cap=sizes[reads%9],n,wanted=((unsigned)bytes-at)/8;if(wanted>cap)wanted=cap;
  unsigned char *out=region+5*page-cap*8;memset(out,0xa5,cap*8);
  n=decoder_read((float *)out,cap);
  if(n!=wanted||decode_error||memcmp(out,expected+at,n*8))return 1;
  for(unsigned i=n*8;i<cap*8;i++)if(out[i]!=0xa5)return 1;
  at+=n*8;reads++;
 }
 if(decoder_read((float *)(region+5*page),0)||decoder_read((float *)(region+5*page-8),1)||decode_error)return 1;
 decoder_close();if(decoder_read((float *)(region+5*page),1))return 1;
 unsigned cancel=1;ogg_cancel_ptr=&cancel;
 if(decoder_open(argv[1])||!decode_error)return 1;decoder_close();ogg_cancel_ptr=NULL;
 if(!decoder_open(argv[1]))return 1;ogg_cancel_ptr=&cancel;
 if(decoder_read((float *)(region+5*page),1)||!decode_error)return 1;
 ogg_cancel_ptr=NULL;if(decoder_read((float *)(region+5*page),1)||!decode_error)return 1;decoder_close();
 if(!decoder_open(argv[1])||decoder_read((float *)(region+5*page-8),1)!=1||decode_error)return 1;
 ogg_cancel_ptr=&cancel;if(decoder_read((float *)(region+5*page),1)||!decode_error)return 1;ogg_cancel_ptr=NULL;decoder_close();
 // Warm allocator/process accounting, then repeated opens must release the
 // bounded extra-channel allocation. Allow one OS page of accounting noise.
 for(unsigned i=0;i<8;i++){if(!decoder_open(argv[1]))return 1;decoder_close();}
 SIZE_T before=committed();if(!before)return 2;
 for(unsigned i=0;i<64;i++){if(!decoder_open(argv[1]))return 1;decoder_close();}
 SIZE_T after=committed();if(after>before+page)return 1;
 VirtualFree(region,0,MEM_RELEASE);free(expected);
 printf("{\"result\":\"passed\",\"channels\":%u,\"depth\":%u,\"guarded_reads\":%u,\"cancel_checks\":4,\"reopen_checks\":64,\"private_bytes_before\":%llu,\"private_bytes_after\":%llu}\n",channels,bits,reads,(unsigned long long)before,(unsigned long long)after);return 0;
}
