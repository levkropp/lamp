/* Test-only operation timings for the actual assembly decoder objects.
   QPC wall time, process CPU and harness memory; no WASAPI/UI or cold-cache
   claim. Correctness belongs to the independent seek verification suites. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <psapi.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <wchar.h>
int decoder_open(const wchar_t *);
void decoder_close(void);
uint64_t decoder_seek(uint64_t);
unsigned decoder_read(float *,unsigned);
extern unsigned decode_error,codec_kind,sample_rate;
extern uint64_t total_frames;
static float pcm[4096];
static LARGE_INTEGER frequency;
static uint64_t tick(void){LARGE_INTEGER value;QueryPerformanceCounter(&value);return (uint64_t)value.QuadPart;}
static uint64_t cpu(void){FILETIME c,e,k,u;if(!GetProcessTimes(GetCurrentProcess(),&c,&e,&k,&u))return 0;return (((uint64_t)k.dwHighDateTime<<32)|k.dwLowDateTime)+(((uint64_t)u.dwHighDateTime<<32)|u.dwLowDateTime);}
static double us(uint64_t ticks){return ticks*1000000.0/frequency.QuadPart;}
static int read_frames(uint64_t count){while(count){unsigned cap=count>2048?2048:(unsigned)count,n=decoder_read(pcm,cap);if(n!=cap||decode_error)return 0;count-=n;}return 1;}
static int opened(const wchar_t *path,uint64_t expected){return decoder_open(path)&&!decode_error&&total_frames==expected&&sample_rate==48000;}
int wmain(int argc,wchar_t **argv){
 if(argc!=4)return 2;uint64_t expected=_wcstoui64(argv[2],NULL,10);unsigned runs=_wtoi(argv[3]);if(!expected||runs<3||runs>20||!QueryPerformanceFrequency(&frequency))return 2;
 PROCESS_MEMORY_COUNTERS_EX initial={0},final={0};initial.cb=final.cb=sizeof(initial);GetProcessMemoryInfo(GetCurrentProcess(),(PROCESS_MEMORY_COUNTERS *)&initial,sizeof(initial));
 uint64_t begin=tick(),first_cpu=cpu();
 if(!opened(argv[1],expected)){fprintf(stderr,"First open failed: %u\n",decode_error);return 1;}unsigned kind=codec_kind;
 uint64_t first_open=tick()-begin,cpu_open=cpu()-first_cpu,ready_begin=tick();if(!read_frames(36000))return 1;uint64_t first_ready=tick()-ready_begin;decoder_close();
 printf("{\"result\":\"passed\",\"codec_kind\":%u,\"frames\":%llu,\"qpc_frequency\":%lld,\"first_open_us\":%.3f,\"first_open_cpu_us\":%.3f,\"first_decode_750ms_us\":%.3f,\"runs\":[",kind,expected,frequency.QuadPart,us(first_open),cpu_open/10.0,us(first_ready));
 const unsigned fractions[]={10,14,50,54,90,94};
 for(unsigned run=0;run<runs;run++)for(unsigned p=0;p<6;p++){
  uint64_t target=expected/100*fractions[p],cpu_begin=cpu(),open_begin=tick();if(!opened(argv[1],expected))return 1;
  uint64_t open_ticks=tick()-open_begin,seek_begin=tick(),base=decoder_seek(target),seek_ticks=tick()-seek_begin;
  if(base>target||decode_error)return 1;uint64_t discarded=target-base,discard_begin=tick();if(!read_frames(discarded))return 1;uint64_t discard_ticks=tick()-discard_begin;
  uint64_t decode_begin=tick();if(!read_frames(expected-target<36000?expected-target:36000))return 1;uint64_t decode_ticks=tick()-decode_begin,ready_ticks=tick()-open_begin,cpu_used=cpu()-cpu_begin;
  uint64_t close_begin=tick();decoder_close();uint64_t close_ticks=tick()-close_begin;
  printf("%s{\"run\":%u,\"target_percent\":%u,\"signal_phase\":\"%s\",\"open_us\":%.3f,\"seek_us\":%.3f,\"discard_us\":%.3f,\"discarded_frames\":%llu,\"decode_750ms_us\":%.3f,\"ready_us\":%.3f,\"close_us\":%.3f,\"cpu_us\":%.3f}",run||p?",":"",run+1,fractions[p],target/48000%60<20?"silence":"noise",us(open_ticks),us(seek_ticks),us(discard_ticks),discarded,us(decode_ticks),us(ready_ticks),us(close_ticks),cpu_used/10.0);
 }
 GetProcessMemoryInfo(GetCurrentProcess(),(PROCESS_MEMORY_COUNTERS *)&final,sizeof(final));
 printf("],\"harness_memory\":{\"initial_working_set_bytes\":%llu,\"peak_working_set_bytes\":%llu,\"initial_private_bytes\":%llu,\"final_private_bytes\":%llu}}\n",(unsigned long long)initial.WorkingSetSize,(unsigned long long)final.PeakWorkingSetSize,(unsigned long long)initial.PrivateUsage,(unsigned long long)final.PrivateUsage);return 0;
}
