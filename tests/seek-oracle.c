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
extern unsigned decoder_seek_probes;
extern unsigned *ogg_cancel_ptr;
extern unsigned mp3_index_count;
extern uint64_t mp3_index_stride,mp3_seek_headers;
extern uint64_t total_frames;
static struct {uint64_t before;float values[4096];uint64_t after;} pcm;
int wmain(int argc,wchar_t **argv){
 if(argc!=4&&argc!=5)return 2;
 unsigned bound=argc==5?(unsigned)_wtoi(argv[4]):UINT32_MAX;
 int invalid=_wtoi(argv[3]);
 if(invalid==5){
  if(!decoder_open(argv[1])||total_frames!=65537ULL*576||mp3_index_count>2048||mp3_index_stride!=64)return 1;
  unsigned points=mp3_index_count;uint64_t target=total_frames/2,base=decoder_seek(target),headers=mp3_seek_headers;
  if(base>target||target-base>3456||headers>=mp3_index_stride||decode_error)return 1;
  while(base<target){unsigned count=target-base>2048?2048:(unsigned)(target-base),n=decoder_read(pcm.values,count);if(n!=count||decode_error)return 1;base+=n;}
  if(decoder_read(pcm.values,2048)!=2048||decode_error)return 1;
  float expected[4096];FILE *reference=_wfopen(argv[2],L"rb");if(!reference||fread(expected,sizeof(expected),1,reference)!=1)return 2;fclose(reference);
  if(memcmp(expected,pcm.values,sizeof(expected)))return 1;
  decoder_close();if(mp3_index_count)return 1;
  printf("{\"result\":\"passed\",\"index_points\":%u,\"stride\":64,\"skimmed_headers\":%llu,\"allocation_bytes\":1114112}\n",points,headers);return 0;
 }
 if(invalid){
  unsigned cancel_open=1;if(invalid==6)ogg_cancel_ptr=&cancel_open;
  int opened=decoder_open(argv[1]);
  if(invalid==1||invalid==6){if(opened||!decode_error)return 1;}
  else if(invalid==3){unsigned cancel=1;if(!opened)return 1;ogg_cancel_ptr=&cancel;if(decoder_seek(UINT64_MAX)||decode_error||decoder_seek_probes||mp3_seek_headers)return 1;ogg_cancel_ptr=NULL;}
  else {if(!opened)return 1;decoder_seek(invalid==4?total_frames/2:UINT64_MAX);
   if(invalid==4){for(unsigned i=0;i<4&&!decode_error;i++)decoder_read(pcm.values,2048);}
   if(!decode_error)return 1;}
  decoder_close();if(mp3_index_count)return 1;if(invalid==6)ogg_cancel_ptr=NULL;puts("{\"result\":\"rejected\"}");return 0;
 }
 FILE *file=_wfopen(argv[2],L"rb");if(!file)return 2;
 if(fseek(file,0,SEEK_END))return 2;long bytes=ftell(file);if(bytes<=0||bytes%8)return 2;
 rewind(file);unsigned char *expected=(unsigned char *)malloc(bytes);if(!expected||fread(expected,1,bytes,file)!=(size_t)bytes)return 2;fclose(file);
 uint64_t frames=(uint64_t)bytes/8;unsigned checks=0,advanced=0,most_probes=0,most_points=0;uint64_t discarded=0,most_discarded=0,most_headers=0;
 const uint64_t requests[]={0,1,119,120,4095,4096,4607,4608,9215,9216,frames/2+17,frames-1,frames,frames+1,UINT64_MAX};
 for(unsigned i=0;i<sizeof(requests)/sizeof(*requests);i++){
  uint64_t target=requests[i]>frames?frames:requests[i];
  if(!decoder_open(argv[1])||(total_frames&&total_frames!=frames))return 1;
  if(codec_kind==3&&(!mp3_index_count||mp3_index_count>2048))return 1;
  uint64_t base=decoder_seek(requests[i]);
  if(base>target||decode_error){fprintf(stderr,"Seek base error %u\n",i);return 1;}if(base)advanced++;
  if(target-base>most_discarded)most_discarded=target-base;
  if(target-base>bound||decoder_seek_probes>66){fprintf(stderr,"Seek work bound exceeded %u: %llu frames, %u probes\n",i,target-base,decoder_seek_probes);return 1;}
  if(decoder_seek_probes>most_probes)most_probes=decoder_seek_probes;
  if(codec_kind==3){if(mp3_seek_headers>=mp3_index_stride)return 1;if(mp3_seek_headers>most_headers)most_headers=mp3_seek_headers;if(mp3_index_count>most_points)most_points=mp3_index_count;}
  while(base<target){unsigned count=target-base>2048?2048:(unsigned)(target-base),n=decoder_read(pcm.values,count);if(n!=count||decode_error)return 1;base+=n;discarded+=n;}
  memset(pcm.values,0xa5,sizeof(pcm.values));pcm.before=0x13579bdf98765432ULL;pcm.after=0x2468ace012345678ULL;
  unsigned count=(i*37)%2048+1,n=decoder_read(pcm.values,count),wanted=frames-target<count?(unsigned)(frames-target):count;
  if(n!=wanted||decode_error||memcmp(pcm.values,expected+target*8,n*8)||pcm.before!=0x13579bdf98765432ULL||pcm.after!=0x2468ace012345678ULL){fprintf(stderr,"Seek PCM mismatch %u at %llu\n",i,target);return 1;}
  for(unsigned j=n*8;j<sizeof(pcm.values);j++)if(((unsigned char *)pcm.values)[j]!=0xa5)return 1;
  decoder_close();if(mp3_index_count||decoder_seek(100)||decoder_read(pcm.values,1))return 1;checks++;
 }
 free(expected);printf("{\"result\":\"passed\",\"checks\":%u,\"advanced\":%u,\"discarded_frames\":%llu,\"maximum_discarded\":%llu,\"maximum_probes\":%u,\"index_points\":%u,\"maximum_skimmed_headers\":%llu}\n",checks,advanced,discarded,most_discarded,most_probes,most_points,most_headers);return 0;
}
