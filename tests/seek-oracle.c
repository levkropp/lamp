/* Test-only direct/indexed seek PCM checks. Runtime objects remain assembly. */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
int decoder_open(const wchar_t *);
void decoder_close(void);
uint64_t decoder_seek(uint64_t);
unsigned decoder_read(float *,unsigned);
extern unsigned decode_error,codec_kind;
extern uint64_t total_frames;
static struct {uint64_t before;float values[4096];uint64_t after;} pcm;
int wmain(int argc,wchar_t **argv){
 if(argc!=4)return 2;
 int invalid=_wtoi(argv[3]);
 if(invalid){
  int opened=decoder_open(argv[1]);
  if(invalid==1){if(opened||!decode_error)return 1;}
  else {if(!opened)return 1;decoder_seek(UINT64_MAX);if(!decode_error)return 1;}
  decoder_close();puts("{\"result\":\"rejected\"}");return 0;
 }
 FILE *file=_wfopen(argv[2],L"rb");if(!file)return 2;
 if(fseek(file,0,SEEK_END))return 2;long bytes=ftell(file);if(bytes<=0||bytes%8)return 2;
 rewind(file);unsigned char *expected=(unsigned char *)malloc(bytes);if(!expected||fread(expected,1,bytes,file)!=(size_t)bytes)return 2;fclose(file);
 uint64_t frames=(uint64_t)bytes/8;unsigned checks=0,advanced=0;uint64_t discarded=0;
 const uint64_t requests[]={0,1,119,120,4095,4096,4607,4608,9215,9216,frames/2+17,frames-1,frames,frames+1,UINT64_MAX};
 for(unsigned i=0;i<sizeof(requests)/sizeof(*requests);i++){
  uint64_t target=requests[i]>frames?frames:requests[i];
  if(!decoder_open(argv[1])||total_frames!=frames)return 1;
  uint64_t base=decoder_seek(requests[i]);
  if(base>target||decode_error){fprintf(stderr,"Seek base error %u\n",i);return 1;}if(base)advanced++;
  while(base<target){unsigned count=target-base>2048?2048:(unsigned)(target-base),n=decoder_read(pcm.values,count);if(n!=count||decode_error)return 1;base+=n;discarded+=n;}
  memset(pcm.values,0xa5,sizeof(pcm.values));pcm.before=0x13579bdf98765432ULL;pcm.after=0x2468ace012345678ULL;
  unsigned count=(i*37)%2048+1,n=decoder_read(pcm.values,count),wanted=frames-target<count?(unsigned)(frames-target):count;
  if(n!=wanted||decode_error||memcmp(pcm.values,expected+target*8,n*8)||pcm.before!=0x13579bdf98765432ULL||pcm.after!=0x2468ace012345678ULL){fprintf(stderr,"Seek PCM mismatch %u at %llu\n",i,target);return 1;}
  for(unsigned j=n*8;j<sizeof(pcm.values);j++)if(((unsigned char *)pcm.values)[j]!=0xa5)return 1;
  decoder_close();if(decoder_seek(100)||decoder_read(pcm.values,1))return 1;checks++;
 }
 free(expected);printf("{\"result\":\"passed\",\"checks\":%u,\"advanced\":%u,\"discarded_frames\":%llu}\n",checks,advanced,discarded);return 0;
}
