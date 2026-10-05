/* Original test-only native-channel read/seek guards and lifecycle checks. */
#include <windows.h>
#include <psapi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int decoder_open(const wchar_t *);
void decoder_close(void);
uint64_t decoder_seek(uint64_t);
unsigned decoder_read(float *,unsigned);
unsigned vorbis_read_native(float *,unsigned);
extern uint64_t total_frames;
extern unsigned source_channels,codec_kind,decode_error;
extern unsigned *ogg_cancel_ptr;
static int failed(unsigned line){fprintf(stderr,"Vorbis native assertion at line %u\n",line);return 1;}
#define CHECK(v) do{if(!(v))return failed(__LINE__);}while(0)
static SIZE_T committed(void){PROCESS_MEMORY_COUNTERS_EX p={0};p.cb=sizeof(p);return GetProcessMemoryInfo(GetCurrentProcess(),(PROCESS_MEMORY_COUNTERS *)&p,sizeof(p))?p.PrivateUsage:0;}
static int reject_probe(const wchar_t *file){
 SYSTEM_INFO info;GetSystemInfo(&info);SIZE_T page=info.dwPageSize,body=(255*257*4+page-1)/page*page;
 unsigned char *area=VirtualAlloc(NULL,body+page,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);DWORD old;
 CHECK(area&&VirtualProtect(area+body,page,PAGE_NOACCESS,&old));unsigned reads=0,late=0;SIZE_T before=0,after=0;
 for(unsigned attempt=0;attempt<24;attempt++){
  int opened=decoder_open(file);if(opened){CHECK(codec_kind==4&&source_channels&&source_channels<=255);late++;
   float *out=(float *)(area+body-source_channels*257*4);unsigned count=0;
   while(vorbis_read_native(out,257)){CHECK(++count<65536);reads++;}
  }
  CHECK(decode_error&&!vorbis_read_native((float *)(area+body),1)&&!decoder_read((float *)(area+body),1));
  decoder_close();CHECK(!vorbis_read_native((float *)(area+body),1));if(attempt==7)before=committed();
 }
 after=committed();CHECK(before&&after<=before+page);VirtualFree(area,0,MEM_RELEASE);
 printf("{\"result\":\"rejected\",\"late_errors\":%u,\"guarded_reads\":%u,\"reopen_checks\":24,\"private_bytes_before\":%llu,\"private_bytes_after\":%llu}\n",late,reads,(uint64_t)before,(uint64_t)after);return 0;
}
int wmain(int argc,wchar_t **argv){
 if(argc==3&&!wcscmp(argv[2],L"--reject"))return reject_probe(argv[1]);
 if(argc!=3&&argc!=4)return 2;unsigned repeats=argc==4?_wtoi(argv[3]):8;
 CHECK(decoder_open(argv[1])&&codec_kind==4&&!decode_error);
 unsigned C=source_channels;uint64_t N=total_frames;CHECK(C&&C<=255&&N<=16000000);
 size_t bytes=(size_t)N*C*4;unsigned char *expected=malloc(bytes?bytes:1);if(!expected)return 2;
 uint64_t at=0;while(at<N){unsigned n=N-at>257?257:(unsigned)(N-at);CHECK(vorbis_read_native((float *)(expected+at*C*4),n)==n&&!decode_error);at+=n;}
 CHECK(!vorbis_read_native((float *)(expected+bytes),1)&&!decode_error);
 FILE *f=_wfopen(argv[2],L"wb");if(!f||fwrite(expected,1,bytes,f)!=bytes||fclose(f))return 2;
 decoder_close();
 SYSTEM_INFO info;GetSystemInfo(&info);SIZE_T page=info.dwPageSize;
 SIZE_T body=(C*257*4+page-1)/page*page;unsigned char *region=VirtualAlloc(NULL,body+2*page,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);DWORD old;
 if(!region||!VirtualProtect(region,page,PAGE_NOACCESS,&old)||!VirtualProtect(region+page+body,page,PAGE_NOACCESS,&old))return 2;
 unsigned char *end=region+page+body;unsigned reads=0,seeks=0;
 CHECK(decoder_open(argv[1]));at=0;const unsigned caps[]={0,1,2,17,257,31,127};
 while(at<N){unsigned cap=caps[reads%7],wanted=N-at<cap?(unsigned)(N-at):cap;unsigned char *out=end-cap*C*4;memset(out,0xa5,cap*C*4);
  CHECK(vorbis_read_native((float *)out,cap)==wanted&&!decode_error&&!memcmp(out,expected+at*C*4,wanted*C*4));
  for(unsigned i=wanted*C*4;i<cap*C*4;i++)CHECK(out[i]==0xa5);at+=wanted;reads++;
 }
 CHECK(!vorbis_read_native((float *)end,0)&&!vorbis_read_native((float *)(end-C*4),1)&&!decode_error);decoder_close();
 // Switching between the public stereo reader and native reader must consume
 // one shared cursor, including packet boundaries and already-buffered PCM.
 unsigned limit=N<8192?(unsigned)N:8192,mixed=0;float *stereo=malloc((limit?limit:1)*8);CHECK(stereo&&decoder_open(argv[1]));
 CHECK(decoder_read(stereo,limit)==limit&&!decode_error);decoder_close();CHECK(decoder_open(argv[1]));at=0;
 while(at<limit){unsigned cap=caps[mixed%7],wanted=limit-at<cap?(unsigned)(limit-at):cap;
  unsigned channels=mixed&1?2:C;unsigned char *out=end-cap*channels*4;memset(out,0xa5,cap*channels*4);
  unsigned n=mixed&1?decoder_read((float *)out,wanted):vorbis_read_native((float *)out,wanted);
  const unsigned char *base=mixed&1?(unsigned char *)stereo:expected;
  CHECK(n==wanted&&!decode_error&&!memcmp(out,base+at*channels*4,n*channels*4));
  for(unsigned j=n*channels*4;j<cap*channels*4;j++)CHECK(out[j]==0xa5);at+=n;mixed++;
 }
 decoder_close();free(stereo);
 const uint64_t requests[]={0,1,31,32,63,64,119,120,4095,4096,N/2,N-1,N,N+1,UINT64_MAX};
 for(unsigned i=0;i<15;i++){
  CHECK(decoder_open(argv[1]));uint64_t target=requests[i]>N?N:requests[i],base=decoder_seek(requests[i]);CHECK(base<=target&&!decode_error);
  while(base<target){unsigned cap=target-base>257?257:(unsigned)(target-base);CHECK(vorbis_read_native((float *)(end-cap*C*4),cap)==cap&&!decode_error);base+=cap;}
  unsigned cap=(i*37)%257+1,wanted=N-target<cap?(unsigned)(N-target):cap;unsigned char *out=end-cap*C*4;memset(out,0xa5,cap*C*4);
  CHECK(vorbis_read_native((float *)out,cap)==wanted&&!decode_error&&!memcmp(out,expected+target*C*4,wanted*C*4));
  for(unsigned j=wanted*C*4;j<cap*C*4;j++)CHECK(out[j]==0xa5);decoder_close();seeks++;
 }
 // Cancellation must also refuse already-buffered native and stereo PCM.
 unsigned cancel=1,cancels=0;CHECK(decoder_open(argv[1]));ogg_cancel_ptr=&cancel;
 CHECK(!vorbis_read_native((float *)end,1)&&decode_error);ogg_cancel_ptr=NULL;
 CHECK(!vorbis_read_native((float *)end,1)&&decode_error);decoder_close();cancels++;
 CHECK(decoder_open(argv[1])&&vorbis_read_native((float *)(end-C*4),1)==1);ogg_cancel_ptr=&cancel;
 CHECK(!vorbis_read_native((float *)end,1)&&decode_error);ogg_cancel_ptr=NULL;decoder_close();cancels++;
 CHECK(decoder_open(argv[1])&&decoder_read((float *)(end-8),1)==1);ogg_cancel_ptr=&cancel;
 CHECK(!decoder_read((float *)end,1)&&decode_error);ogg_cancel_ptr=NULL;decoder_close();cancels++;
 CHECK(!vorbis_read_native((float *)end,1));
 for(unsigned i=0;i<8;i++){CHECK(decoder_open(argv[1]));decoder_close();}SIZE_T before=committed();CHECK(before);
 for(unsigned i=0;i<repeats;i++){CHECK(decoder_open(argv[1]));decoder_close();}SIZE_T after=committed();CHECK(after<=before+page);
 VirtualFree(region,0,MEM_RELEASE);free(expected);
 printf("{\"result\":\"passed\",\"channels\":%u,\"frames\":%llu,\"guarded_reads\":%u,\"mixed_read_checks\":%u,\"native_seeks\":%u,\"cancel_checks\":%u,\"reopen_checks\":%u,\"private_bytes_before\":%llu,\"private_bytes_after\":%llu}\n",C,N,reads,mixed,seeks,cancels,repeats,(uint64_t)before,(uint64_t)after);return 0;
}
