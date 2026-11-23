/* Test-only guarded Matroska mappings and Speex packet-track output. */
#include "lamp-test.h"
#include <math.h>
LAMP_ABI int mkv_open(const unsigned char *,const unsigned char *);
LAMP_ABI void track_close(void);
LAMP_ABI unsigned track_read(float *,unsigned);
extern unsigned decode_error,track_active,sample_rate,source_channels;
extern unsigned track_choice,track_choice_used,audio_tracks_count,audio_track_selected;
extern uint64_t track_count,total_frames;
static uint64_t checks,words,cases,prefixes,mutations;
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"guard check line %d failed\n",__LINE__);exit(1);}}while(0)
typedef struct{unsigned char *base,*data;size_t size,body,page;} Guard;
static Guard guarded(size_t n){SYSTEM_INFO info;GetSystemInfo(&info);size_t page=info.dwPageSize,body=(n+page-1)/page*page;if(!body)body=page;Guard g={0};DWORD old;g.base=VirtualAlloc(NULL,body+2*page,MEM_RESERVE|MEM_COMMIT,PAGE_NOACCESS);CHECK(g.base&&VirtualProtect(g.base+page,body,PAGE_READWRITE,&old));g.data=g.base+page+body-n;g.size=n;g.body=body;g.page=page;return g;}
static void readonly(Guard*g){DWORD old;CHECK(VirtualProtect(g->base+g->page,g->body,PAGE_READONLY,&old));}
static void release(Guard*g){CHECK(VirtualFree(g->base,0,MEM_RELEASE));}
static unsigned char *load(const lamp_char*path,size_t*bytes){FILE*f=lamp_fopen(path,LT("rb"));CHECK(f);CHECK(!fseek(f,0,SEEK_END));long n=ftell(f);CHECK(n>0&&n<=16777216);rewind(f);unsigned char*p=malloc(n);CHECK(p&&fread(p,1,n,f)==(size_t)n);fclose(f);*bytes=n;return p;}
static void exercise(const unsigned char*data,size_t bytes,const unsigned char*expected,size_t expected_bytes,unsigned rate,unsigned channels,int exact){
 Guard in=guarded(bytes),out=guarded(32+997*8);if(bytes)memcpy(in.data,data,bytes);readonly(&in);decode_error=0;track_choice_used=audio_tracks_count=audio_track_selected=0;
 int opened=mkv_open(in.data,in.data+bytes);uint64_t position=0;
 if(exact)CHECK(opened==1&&!decode_error&&sample_rate==rate&&source_channels==channels&&total_frames*8==expected_bytes);
 if(opened==1){CHECK(track_read((float*)(out.data+32),0)==0);for(unsigned turn=0;;turn++){
  CHECK(turn<65536);unsigned cap=1+(turn*137)%997;memset(out.data,0xa5,out.size);unsigned n=track_read((float*)(out.data+32),cap);CHECK(n<=cap);
  for(unsigned j=0;j<32;j++)CHECK(out.data[j]==0xa5);for(size_t j=32+(size_t)n*8;j<out.size;j++)CHECK(out.data[j]==0xa5);
  if(!decode_error){float*p=(float*)(out.data+32);for(unsigned j=0;j<n*2;j++)CHECK(isfinite(p[j]));if(exact){CHECK((position+n)*8<=expected_bytes);CHECK(!memcmp(p,expected+position*8,(size_t)n*8));words+=(uint64_t)n*2;}position+=n;}else CHECK(!exact);
  if(!n||decode_error)break;
 }}
 if(exact)CHECK(!decode_error&&position*8==expected_bytes);
 track_close();CHECK(!track_active&&!track_count&&!track_read((float*)(out.data+32),1));release(&out);release(&in);cases++;
}
int lamp_main(int argc,lamp_char**argv){
 if(argc!=7)return 2;size_t bytes,reference_bytes;unsigned char*data=load(argv[1],&bytes),*reference=load(argv[2],&reference_bytes);unsigned rate=lamp_atoi(argv[3]),channels=lamp_atoi(argv[4]);track_choice=lamp_atoi(argv[5]);exercise(data,bytes,reference,reference_bytes,rate,channels,1);
 if(lamp_atoi(argv[6])){
  for(size_t n=0;n<bytes&&n<1024;n++){exercise(data,n,NULL,0,0,0,0);prefixes++;}
  size_t step=bytes/256+1;for(size_t n=1024;n<bytes;n+=step){exercise(data,n,NULL,0,0,0,0);prefixes++;}
  unsigned seed=0x462e7;for(unsigned i=0;i<512;i++){unsigned char*p=malloc(bytes);CHECK(p);memcpy(p,data,bytes);seed=seed*1664525u+1013904223u;size_t at=seed%bytes;seed=seed*1664525u+1013904223u;p[at]^=1u<<(seed>>29);exercise(p,bytes,NULL,0,0,0,0);free(p);mutations++;}
 }
 free(data);free(reference);printf("{\"result\":\"passed\",\"checks\":%llu,\"exact_float_words\":%llu,\"guarded_cases\":%llu,\"protected_prefixes\":%llu,\"mutations\":%llu}\n",(unsigned long long)checks,(unsigned long long)words,(unsigned long long)cases,(unsigned long long)prefixes,(unsigned long long)mutations);return 0;
}
