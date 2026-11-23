/* Test-only independent sample-mask model for sparse presentation cuts. */
#include "lamp-test.h"
typedef struct{const void*p;uint64_t start;unsigned bytes,samples;} Packet;
uint64_t track_count,track_start_trim,track_end_trim,total_frames;
unsigned sample_rate=8000;
extern unsigned track_cut_count;
LAMP_ABI void track_cuts_close(void);
LAMP_ABI int track_cut_add(uint64_t,uint64_t,int64_t);
LAMP_ABI int track_cuts_finish(Packet*,uint64_t,uint64_t);
LAMP_ABI uint64_t track_cut_to_raw(uint64_t);
LAMP_ABI uint64_t track_cut_to_presented(uint64_t);
LAMP_ABI uint64_t track_cut_probe_buffer(uint64_t,unsigned,unsigned);
static uint64_t checks,cases,positions,spans,allocations,peak_commit;
static unsigned seed=0x73256,deny_reserve,deny_commit;static uint64_t committed;
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"cut check failed line%d case%llu\n",__LINE__,(unsigned long long)cases);exit(1);}}while(0)
static unsigned next(void){seed=seed*1664525u+1013904223u;return seed;}
LAMP_ABI void*mem_reserve(uint64_t n){CHECK(n==536870912);if(deny_reserve)return NULL;void*p=VirtualAlloc(NULL,(SIZE_T)n,MEM_RESERVE,PAGE_NOACCESS);CHECK(p);allocations++;committed=0;return p;}
LAMP_ABI void*mem_commit(void*p,uint64_t n){CHECK(n==65536);if(deny_commit)return NULL;
#ifdef _WIN32
 void*q=VirtualAlloc(p,(SIZE_T)n,MEM_COMMIT,PAGE_READWRITE);CHECK(q==p);
#else
 DWORD old;CHECK(VirtualProtect(p,(SIZE_T)n,PAGE_READWRITE,&old));
#endif
 committed+=n;if(committed>peak_commit)peak_commit=committed;return p;}
LAMP_ABI void mem_free(void*p){CHECK(allocations==1&&VirtualFree(p,0,MEM_RELEASE));allocations--;}
int main(void){
 for(unsigned trial=0;trial<2048;trial++){
  Packet table[40];unsigned char visible[8192];unsigned selected[8192];track_count=1+next()%40;unsigned raw=0;
  for(unsigned i=0;i<track_count;i++){table[i]=(Packet){NULL,raw,0,next()%161};raw+=table[i].samples;}
  track_start_trim=next()%(raw+1);track_end_trim=next()%(raw-track_start_trim+1);unsigned end=raw-(unsigned)track_end_trim;total_frames=end-track_start_trim;
  for(unsigned i=0;i<raw;i++)visible[i]=i>=track_start_trim&&i<end;
  for(unsigned first=0;first<track_count;){unsigned last=first+1+next()%5;if(last>track_count)last=(unsigned)track_count;unsigned begin=(unsigned)table[first].start,stop=(unsigned)(table[last-1].start+table[last-1].samples),n=next()%(stop-begin+1),head=next()&1;int64_t ns=(int64_t)n*125000;if(head)ns=-ns;CHECK(track_cut_add(first,last,ns));for(unsigned i=head?begin:stop-n;i<(head?begin+n:stop);i++)visible[i]=0;first=last;}
  unsigned count=0;for(unsigned i=0;i<raw;i++)if(visible[i])selected[count++]=i;
  CHECK(track_cuts_finish(table,track_count,raw));CHECK(total_frames==count);uint64_t before=total_frames;CHECK(!track_cuts_finish(table,track_count,raw)&&total_frames==before);CHECK(!track_cut_add(0,1,1));
  for(unsigned i=0;i<=count;i++){CHECK(track_cut_to_raw(i)==(i<count?selected[i]:end));positions++;}
  unsigned seen=0;for(unsigned i=0;i<=end;i++){CHECK(track_cut_to_presented(i)==seen);if(i<end&&visible[i])seen++;positions++;}
  for(unsigned i=0;i<track_count;i++){unsigned begin=(unsigned)table[i].start,n=table[i].samples,used=track_start_trim>begin?(unsigned)(track_start_trim-begin):0;if(used>n)used=n;unsigned avail=end>begin?end-begin:0;if(avail>n)avail=n;if(used>avail)used=avail;uint64_t result=track_cut_probe_buffer(begin,used,avail);unsigned a=(unsigned)result,b=(unsigned)(result>>32);CHECK(a<=b&&b<=avail);unsigned first=n,last=0;for(unsigned j=0;j<n;j++)if(visible[begin+j]){if(first==n)first=j;last=j+1;}if(first==n)CHECK(a==b);else CHECK(a==first&&b==last);spans++;}
  track_cuts_close();CHECK(!allocations&&!track_cut_count);cases++;
 }
 /* Cross a commit boundary with thousands of alternating block edges. */
 Packet *long_table=calloc(3000,sizeof(*long_table));CHECK(long_table);track_count=3000;track_start_trim=track_end_trim=0;total_frames=12000;
 for(unsigned i=0;i<3000;i++){long_table[i]=(Packet){NULL,i*4,0,4};CHECK(track_cut_add(i,i+1,(i&1)?-250000:250000));}
 CHECK(track_cuts_finish(long_table,3000,12000)&&total_frames==6000);
 for(unsigned i=0;i<6000;i++){CHECK(track_cut_to_raw(i)==(i/2)*4+((i/2)&1?2:0)+i%2);positions++;}
 for(unsigned i=0;i<3000;i++){uint64_t span=track_cut_probe_buffer(i*4,0,4);CHECK((unsigned)span==((i&1)?2u:0u)&&(unsigned)(span>>32)==((i&1)?4u:2u));spans++;}
 track_cuts_close();CHECK(!allocations&&!track_cut_count);free(long_table);
 Packet p[3]={{NULL,0,0,10},{NULL,10,0,10},{NULL,20,0,10}};track_count=3;track_start_trim=track_end_trim=0;
 deny_reserve=1;CHECK(!track_cut_add(0,1,125000));track_cuts_close();CHECK(!allocations);deny_reserve=0;
 deny_commit=1;CHECK(!track_cut_add(0,1,125000));track_cuts_close();CHECK(!allocations);deny_commit=0;
 CHECK(!track_cut_add(2,1,1)&&!track_cut_add(0,4,1));CHECK(track_cut_add(0,1,125000));CHECK(!track_cut_add(0,2,125000));track_cuts_close();
 for(unsigned i=0;i<2;i++){total_frames=30;CHECK(track_cut_add(0,1,i?INT64_MIN:INT64_MAX));CHECK(!track_cuts_finish(p,3,30));CHECK(!track_cuts_finish(p,3,30));track_cuts_close();CHECK(!allocations);}
 /* Positive/negative half-sample ties round away from zero at 8 kHz. */
 for(unsigned head=0;head<2;head++)for(unsigned i=0;i<3;i++){total_frames=30;int64_t ns=62499+i;if(head)ns=-ns;CHECK(track_cut_add(0,1,ns));CHECK(track_cuts_finish(p,3,30));CHECK(total_frames==30-(i!=0));uint64_t span=track_cut_probe_buffer(0,0,10);CHECK((unsigned)span==(head&&i!=0?1u:0u));CHECK((unsigned)(span>>32)==(!head&&i!=0?9u:10u));track_cuts_close();cases++;}
 track_cut_count=1u<<24;CHECK(!track_cut_add(0,1,1));track_cut_count=0;track_cuts_close();
 printf("{\"result\":\"passed\",\"cases\":%llu,\"checks\":%llu,\"mapped_positions\":%llu,\"packet_spans\":%llu,\"peak_committed_bytes\":%llu}\n",(unsigned long long)cases,(unsigned long long)checks,(unsigned long long)positions,(unsigned long long)spans,(unsigned long long)peak_commit);return 0;
}
