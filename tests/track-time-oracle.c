/* Test-only independent per-sample media timeline and source decoder model. */
#include "lamp-test.h"
uint64_t track_start_trim,track_end_trim,total_frames;
unsigned sample_rate=8000,decode_error;
unsigned *ogg_cancel_ptr;
extern unsigned track_time_enabled,track_time_active,track_time_event_count,track_time_span_count;
extern uint64_t track_time_source_frames,track_time_scale_ns;
extern double track_time_track_scale;
LAMP_ABI void track_time_close(void);
LAMP_ABI int track_time_event(uint64_t,int64_t);
LAMP_ABI int track_time_anchor(uint64_t,uint64_t,int);
LAMP_ABI int track_time_anchor_ns(uint64_t,int64_t);
LAMP_ABI int track_time_finish(uint64_t);
LAMP_ABI uint64_t track_time_seek(uint64_t);
LAMP_ABI unsigned track_time_read(float*,unsigned);
static uint64_t checks,cases,positions,words,allocations,peak_commit,committed;
static unsigned seed=0x914701,deny_reserve,deny_commit,fail_after_commit,cut_count,source_count,source_at,tail_calls;
static unsigned source[8192],expected[32768];
static struct {uint64_t a,b;} cuts[128];
#define CHECK(x) do {checks++;if(!(x)){fprintf(stderr,"timeline check failed line%d case%llu error%u\n",__LINE__,(unsigned long long)cases,decode_error);exit(1);}} while(0)
static unsigned next(void){seed=seed*1664525u+1013904223u;return seed;}
LAMP_ABI void*mem_reserve(uint64_t n){CHECK(n==268435456||n==536870912);if(deny_reserve)return NULL;void*p=VirtualAlloc(NULL,(SIZE_T)n,MEM_RESERVE,PAGE_NOACCESS);CHECK(p);allocations++;return p;}
LAMP_ABI void*mem_commit(void*p,uint64_t n){CHECK(n==65536);if(deny_commit||(fail_after_commit&&committed/65536>=fail_after_commit))return NULL;
#ifdef _WIN32
 void*q=VirtualAlloc(p,(SIZE_T)n,MEM_COMMIT,PAGE_READWRITE);CHECK(q==p);
#else
 DWORD old;CHECK(VirtualProtect(p,(SIZE_T)n,PAGE_READWRITE,&old));
#endif
 committed+=n;if(committed>peak_commit)peak_commit=committed;return p;}
LAMP_ABI void mem_free(void*p){CHECK(allocations&&VirtualFree(p,0,MEM_RELEASE));allocations--;}
/* Assembly returns the cut end in RDX; use a tiny test wrapper below. */
LAMP_ABI const uint64_t*test_time_cut(unsigned i){static uint64_t result[2];result[0]=i<cut_count?cuts[i].a:UINT64_MAX;result[1]=i<cut_count?cuts[i].b:UINT64_MAX;return result;}
static void sample(float*p,unsigned index){p[0]=(float)index;p[1]=-(float)index;}
LAMP_ABI unsigned track_read(float*p,unsigned n){if(ogg_cancel_ptr&&*ogg_cancel_ptr){decode_error=61;return 0;}unsigned got=source_count-source_at;if(got>n)got=n;for(unsigned i=0;i<got;i++)sample(p+i*2,source[source_at++]);if(!got)tail_calls++;return got;}
LAMP_ABI uint64_t track_seek(uint64_t target){if(target>source_count)target=source_count;source_at=(unsigned)target/7*7;return source_at;}
static struct {uint64_t a;float pcm[512];uint64_t b;} out;
static void read_exact(unsigned cap,unsigned want,const unsigned*data){memset(out.pcm,0xa5,sizeof(out.pcm));out.a=0x125687abcdef0432ULL;out.b=0x9834321abcdef987ULL;unsigned n=track_time_read(out.pcm,cap);CHECK(n==want&&!decode_error&&out.a==0x125687abcdef0432ULL&&out.b==0x9834321abcdef987ULL);for(unsigned i=0;i<n;i++){CHECK(out.pcm[i*2]==(float)data[i]&&out.pcm[i*2+1]==-(float)data[i]);words+=2;}for(unsigned i=n*8;i<sizeof(out.pcm);i++)CHECK(((unsigned char*)out.pcm)[i]==0xa5);}
static int removed(unsigned i){for(unsigned j=0;j<cut_count;j++)if(cuts[j].a<=i&&i<cuts[j].b)return 1;return 0;}
static void clear(void){track_time_close();CHECK(!allocations&&!track_time_active&&!track_time_event_count&&!track_time_span_count);track_time_enabled=1;decode_error=0;source_at=source_count=cut_count=tail_calls=0;committed=0;track_start_trim=track_end_trim=0;}
int main(void){
 for(unsigned negative=0;negative<2;negative++){clear();sample_rate=8000;track_time_scale_ns=1;CHECK(track_time_anchor_ns(0,negative?-125000:125000));source_count=4;for(unsigned i=0;i<4;i++)source[i]=i+1;total_frames=4;CHECK(track_time_finish(4)&&total_frames==(negative?3u:5u));unsigned plus[5]={0,1,2,3,4},minus[3]={2,3,4};read_exact(5,negative?3:5,negative?minus:plus);cases++;}
 clear();CHECK(!track_time_anchor_ns(0,INT64_MIN));track_time_scale_ns=0;CHECK(!track_time_anchor_ns(0,0));clear();sample_rate=0;CHECK(!track_time_anchor_ns(0,2000000));sample_rate=8000;clear();CHECK(track_time_anchor_ns(8,2000000)&&!track_time_event_count);cases++;
 for(unsigned trial=0;trial<512;trial++){
  clear();unsigned raw=100+next()%1200;int64_t offset[8192];for(unsigned i=0;i<raw;i++)offset[i]=0;
  track_start_trim=next()%31;track_end_trim=next()%31;unsigned end=raw-(unsigned)track_end_trim;
  for(unsigned at=0;at<raw;){unsigned stop=at+1+next()%100;if(stop>raw)stop=raw;int64_t delta=(int)(next()%501)-250;CHECK(track_time_event(at,delta));for(unsigned i=at;i<stop;i++)offset[i]=delta;at=stop;}
  for(unsigned at=(unsigned)track_start_trim;at<end;){unsigned stop=at+1+next()%100;if(stop>end)stop=end;if((next()&3)==0){cuts[cut_count].a=at;cuts[cut_count++].b=at+(stop-at)/2;}at=stop;}
  unsigned length=0;for(unsigned raw_at=(unsigned)track_start_trim;raw_at<end;raw_at++)if(!removed(raw_at)){source[source_count++]=raw_at+1;int64_t dst=(int64_t)raw_at-(int64_t)track_start_trim+offset[raw_at];if(dst<0||dst<(int64_t)length)continue;CHECK(dst<32768);while(length<(unsigned)dst)expected[length++]=0;expected[length++]=raw_at+1;}
  total_frames=source_count;CHECK(track_time_finish(raw)&&total_frames==length);unsigned at=0;while(at<length){unsigned n=1+next()%256;if(n>length-at)n=length-at;read_exact(n,n,expected+at);at+=n;}read_exact(1,0,expected);CHECK(source_at==source_count&&tail_calls);CHECK(!track_time_finish(raw));
  for(unsigned target=0;target<=length;target+=1+next()%29){uint64_t base=track_time_seek(target);CHECK(!decode_error&&base<=target);if(track_time_active)CHECK(base==target);while(base<target){unsigned n=target-base>256?256:(unsigned)(target-base);read_exact(n,n,expected+(unsigned)base);base+=n;}unsigned n=length-target;if(n>256)n=256;read_exact(256,n,expected+target);positions++;}
  uint64_t base=track_time_seek(UINT64_MAX);CHECK(base<=length);while(base<length){unsigned n=length-base>256?256:(unsigned)(length-base);read_exact(n,n,expected+base);base+=n;}read_exact(1,0,expected);CHECK(track_time_seek(0)==0);unsigned n=length<17?length:17;read_exact(17,n,expected);cases++;
 }
 /* Fine clocks preserve one-sample gaps; a whole timestamp tick is jitter. */
 clear();track_time_scale_ns=1;CHECK(track_time_anchor(0,0,0));CHECK(!track_time_event_count);CHECK(track_time_anchor(8,1125000,0));CHECK(track_time_event_count==1);source_count=16;for(unsigned i=0;i<16;i++)source[i]=i+1;total_frames=16;CHECK(track_time_finish(16)&&total_frames==17);unsigned gap[17];for(unsigned i=0;i<17;i++)gap[i]=i<8?i+1:i==8?0:i;read_exact(17,17,gap);cases++;
 clear();track_time_scale_ns=1000000;CHECK(track_time_anchor(8,2,0));CHECK(!track_time_event_count);cases++;
 /* Signed relative timestamps and fractional legacy TrackTimestampScale. */
 clear();track_time_scale_ns=125000;CHECK(track_time_anchor(0,0,-3));CHECK(track_time_event_count==1);source_count=8;for(unsigned i=0;i<8;i++)source[i]=i+1;total_frames=8;CHECK(track_time_finish(8)&&total_frames==5);unsigned clipped[5]={4,5,6,7,8};read_exact(5,5,clipped);cases++;
 clear();track_time_scale_ns=1;track_time_track_scale=0.5;CHECK(track_time_anchor(0,1000000,-25000));CHECK(track_time_event_count==1);cases++;
 for(unsigned negative=0;negative<2;negative++){clear();sample_rate=1000000000;track_time_scale_ns=1;track_time_track_scale=0.5;CHECK(track_time_anchor(0,0,negative?-3:3));source_count=4;for(unsigned i=0;i<4;i++)source[i]=i+1;total_frames=4;CHECK(track_time_finish(4)&&total_frames==(negative?2u:6u));unsigned positive[6]={0,0,1,2,3,4},clipped_half[2]={3,4};read_exact(6,negative?2:6,negative?clipped_half:positive);cases++;}sample_rate=8000;
 clear();track_time_scale_ns=1;CHECK(track_time_anchor(0,((uint64_t)INT64_MAX)+1,-1));CHECK(track_time_event_count==1);clear();track_time_scale_ns=1;CHECK(!track_time_anchor(0,INT64_MAX,1));cases++;
 /* Thousands of genuine discontinuities cross both allocation commits. */
 clear();source_count=5000;total_frames=5000;memset(expected,0,sizeof(expected));for(unsigned i=0;i<5000;i++){source[i]=i+1;expected[i*3]=i+1;CHECK(track_time_event(i,(int64_t)i*2));}CHECK(track_time_finish(5000)&&total_frames==14998&&track_time_span_count==5000);for(unsigned at=0;at<14998;){unsigned n=14998-at;if(n>256)n=256;read_exact(n,n,expected+at);at+=n;}CHECK(track_time_seek(14997)==14997);read_exact(1,1,expected+14997);cases++;
 clear();fail_after_commit=1;for(unsigned i=0;i<4096;i++)CHECK(track_time_event(i,(int64_t)i+1));CHECK(!track_time_event(4096,4097)&&track_time_event_count==4096);fail_after_commit=0;clear();
 track_time_event_count=1u<<24;CHECK(!track_time_event(0,1));track_time_event_count=0;clear();track_time_span_count=1u<<24;total_frames=4;CHECK(!track_time_finish(4));track_time_span_count=0;clear();
 /* A vast gap allocates a map, never a gap-sized sample buffer. */
 clear();CHECK(track_time_event(0,1000000000000LL));source_count=4;for(unsigned i=0;i<4;i++)source[i]=i+1;total_frames=4;CHECK(track_time_finish(4)&&total_frames==1000000000004ULL);CHECK(track_time_seek(999999999999ULL)==999999999999ULL);unsigned huge[5]={0,1,2,3,4};read_exact(5,5,huge);cases++;
 clear();deny_reserve=1;CHECK(!track_time_event(0,1));deny_reserve=0;clear();deny_commit=1;CHECK(!track_time_event(0,1));deny_commit=0;clear();CHECK(track_time_event(0,1));source_count=4;total_frames=4;deny_reserve=1;CHECK(!track_time_finish(4));deny_reserve=0;clear();
 CHECK(track_time_event(0,1));source_count=4;total_frames=4;deny_commit=1;CHECK(!track_time_finish(4));deny_commit=0;clear();
 CHECK(track_time_event(0,INT64_MAX));source_count=4;total_frames=4;CHECK(!track_time_finish(4));clear();CHECK(track_time_event(7,3));CHECK(!track_time_event(6,4));clear();track_time_scale_ns=0;CHECK(!track_time_anchor(0,0,0));clear();track_time_scale_ns=1;CHECK(!track_time_anchor(0,UINT64_MAX,0));clear();
 CHECK(track_time_event(0,4));source_count=4;total_frames=4;CHECK(track_time_finish(4));unsigned cancel=1;ogg_cancel_ptr=&cancel;CHECK(track_time_seek(7)==0&&!decode_error);CHECK(track_time_read(out.pcm,1)==0&&decode_error==61);ogg_cancel_ptr=NULL;clear();
 printf("{\"result\":\"passed\",\"cases\":%llu,\"checks\":%llu,\"seek_positions\":%llu,\"float_words\":%llu,\"peak_committed_bytes\":%llu}\n",(unsigned long long)cases,(unsigned long long)checks,(unsigned long long)positions,(unsigned long long)words,(unsigned long long)peak_commit);return 0;
}
