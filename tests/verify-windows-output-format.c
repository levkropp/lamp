/* Original SDK/model oracle for exclusive-mode output primitives. No playback. */
#define COBJMACROS
#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <stdint.h>
#include <stdio.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <stddef.h>
#include <xmmintrin.h>
typedef struct {WAVEFORMATEXTENSIBLE format;uint32_t kind,reserved;} Profile;
int output_format_make(Profile *,unsigned,unsigned,size_t);
HRESULT output_format_choose(IAudioClient *,unsigned,Profile *,size_t);
int output_format_pack(void *,const float *,unsigned,unsigned,size_t,float);
typedef struct {Profile profile;IAudioClient*client;IAudioRenderClient*render;IAudioClock*clock;uint64_t frequency;uint32_t frames,reserved;int64_t period;} Stream;
HRESULT output_exclusive_open(IMMDevice*,unsigned,HANDLE,Stream*);
void output_exclusive_close(Stream*);
#define CHECK(x) do{if(!(x)){fprintf(stderr,"Output-format assertion %d: %s\n",__LINE__,#x);return 1;}}while(0)
static unsigned checks;static uint64_t values;
static unsigned width(unsigned k){return k==3||k==7?3:k==4||k==8?2:4;}
static unsigned bits(unsigned k){return k==2?24:width(k)*8;}
static int floating(unsigned k){return k==0||k==5;}
static int profile_valid(const Profile*p,unsigned rate,unsigned k){
 const WAVEFORMATEXTENSIBLE*f=&p->format;const WAVEFORMATEX*w=&f->Format;
 if(sizeof(Profile)!=48||p->kind!=k||p->reserved||w->nChannels!=2||w->nSamplesPerSec!=rate||w->nBlockAlign!=2*width(k)||w->nAvgBytesPerSec!=rate*w->nBlockAlign||w->wBitsPerSample!=width(k)*8)return 0;
 if(k<5){const unsigned char tail[]={0x80,0,0,0xaa,0,0x38,0x9b,0x71};return w->wFormatTag==WAVE_FORMAT_EXTENSIBLE&&w->cbSize==22&&f->Samples.wValidBitsPerSample==bits(k)&&f->dwChannelMask==3&&f->SubFormat.Data1==(floating(k)?3:1)&&f->SubFormat.Data2==0&&f->SubFormat.Data3==0x10&&!memcmp(f->SubFormat.Data4,tail,8);}
 return w->wFormatTag==(floating(k)?WAVE_FORMAT_IEEE_FLOAT:WAVE_FORMAT_PCM)&&!w->cbSize&&!f->Samples.wValidBitsPerSample&&!f->dwChannelMask;
}
typedef struct{IAudioClient base;unsigned calls,accept;HRESULT error;unsigned error_at;int valid;} Mock;
static HRESULT STDMETHODCALLTYPE supported(IAudioClient*self,AUDCLNT_SHAREMODE mode,const WAVEFORMATEX*fmt,WAVEFORMATEX**closest){
 Mock*m=(Mock*)self;unsigned k=m->calls++;if(mode!=AUDCLNT_SHAREMODE_EXCLUSIVE||closest||k>=9||!profile_valid((const Profile*)fmt,48000,k))m->valid=0;
 if(k==m->error_at)return m->error;return m->accept&(1u<<k)?S_OK:AUDCLNT_E_UNSUPPORTED_FORMAT;
}
static IAudioClientVtbl table={0};
static void reference(unsigned char*out,const float*in,unsigned n,unsigned kind,float volume){
 for(unsigned i=0;i<n*2;i++){
  double x=isfinite(in[i])?(double)in[i]*(double)volume:0.;if(x>1)x=1;if(x< -1)x=-1;
  if(floating(kind)){float f=(float)x;memcpy(out+i*4,&f,4);}
  else{unsigned b=bits(kind);double scale=ldexp(1.,b-1);int64_t q=x<0?-(int64_t)floor(-x*scale+.5):(int64_t)floor(x*scale+.5);
   if(q>(int64_t)scale-1)q=(int64_t)scale-1;uint32_t u=(uint32_t)q;if(kind==2)u<<=8;
   for(unsigned j=0;j<width(kind);j++)out[i*width(kind)+j]=(unsigned char)(u>>(j*8));
  }
 }
}
static unsigned char*guarded(size_t bytes,unsigned char**allocation,size_t*body){SYSTEM_INFO info;GetSystemInfo(&info);size_t p=info.dwPageSize;*body=(bytes+p-1)/p*p;*allocation=VirtualAlloc(NULL,*body+2*p,MEM_RESERVE|MEM_COMMIT,PAGE_NOACCESS);DWORD old;if(!*allocation||!VirtualProtect(*allocation+p,*body,PAGE_READWRITE,&old))return NULL;return *allocation+p+*body;}
/* Fresh-client setup, alignment recovery and failure ownership oracle. The
 * mock has no Start or GetCurrentPadding method and cannot touch hardware. */
typedef struct {IAudioClient base;unsigned number,initialized;} SetupClient;
static struct {unsigned calls,fail_at,null_at,align,activations,live_client,live_render,live_clock,releases,valid;HRESULT failure;uint32_t frames;uint64_t frequency;int64_t period,minimum;char release_order[16];} setup;
static IMMDeviceVtbl device_table={0};static IAudioClientVtbl setup_table={0};
static IAudioRenderClientVtbl render_table={0};static IAudioClockVtbl clock_table={0};
static IMMDevice setup_device={&device_table};static SetupClient setup_clients[2];
static IAudioRenderClient setup_render={&render_table};static IAudioClock setup_clock={&clock_table};
static GUID expected_client,expected_render,expected_clock;
static HRESULT setup_step(void){setup.calls++;return setup.calls==setup.fail_at?setup.failure:S_OK;}
static ULONG STDMETHODCALLTYPE setup_client_release(IAudioClient*self){if(!setup.live_client||self!=&setup_clients[setup.activations-1].base)setup.valid=0;else setup.live_client--;setup.release_order[setup.releases++]='C';return 0;}
static ULONG STDMETHODCALLTYPE setup_render_release(IAudioRenderClient*self){if(self!=&setup_render||!setup.live_render)setup.valid=0;else setup.live_render--;setup.release_order[setup.releases++]='R';return 0;}
static ULONG STDMETHODCALLTYPE setup_clock_release(IAudioClock*self){if(self!=&setup_clock||!setup.live_clock)setup.valid=0;else setup.live_clock--;setup.release_order[setup.releases++]='K';return 0;}
static HRESULT STDMETHODCALLTYPE setup_activate(IMMDevice*self,REFIID iid,DWORD context,PROPVARIANT*activation,void**out){
 if(self!=&setup_device||memcmp(iid,&expected_client,sizeof(IID))||context!=CLSCTX_INPROC_SERVER||activation||setup.live_client||setup.activations>=2)setup.valid=0;
 HRESULT hr=setup_step();if(hr!=S_OK||setup.calls==setup.null_at)return hr;
 SetupClient*c=&setup_clients[setup.activations];c->base.lpVtbl=&setup_table;c->number=setup.activations++;c->initialized=0;*out=&c->base;setup.live_client++;return S_OK;
}
static HRESULT STDMETHODCALLTYPE setup_supported(IAudioClient*self,AUDCLNT_SHAREMODE mode,const WAVEFORMATEX*fmt,WAVEFORMATEX**closest){
 if(self!=&setup_clients[0].base||mode!=AUDCLNT_SHAREMODE_EXCLUSIVE||closest||!profile_valid((const Profile*)fmt,48000,((const Profile*)fmt)->kind))setup.valid=0;
 HRESULT hr=setup_step();if(hr!=S_OK)return hr;return ((const Profile*)fmt)->kind==4?S_OK:AUDCLNT_E_UNSUPPORTED_FORMAT;
}
static HRESULT STDMETHODCALLTYPE setup_period(IAudioClient*self,REFERENCE_TIME*normal,REFERENCE_TIME*minimum){if(self!=&setup_clients[0].base)setup.valid=0;HRESULT hr=setup_step();if(hr==S_OK){*normal=setup.period;*minimum=setup.minimum;}return hr;}
static HRESULT STDMETHODCALLTYPE setup_initialize(IAudioClient*self,AUDCLNT_SHAREMODE mode,DWORD flags,REFERENCE_TIME duration,REFERENCE_TIME period,const WAVEFORMATEX*fmt,LPCGUID session){
 SetupClient*c=(SetupClient*)self;int64_t expected=c->number?((int64_t)setup.frames*10000000+24000)/48000:setup.period>setup.minimum?setup.period:setup.minimum;if(!c->number&&expected<100000)expected=100000;
 if(c->initialized++||c->number!=setup.activations-1||mode!=AUDCLNT_SHAREMODE_EXCLUSIVE||flags!=AUDCLNT_STREAMFLAGS_EVENTCALLBACK||duration!=period||duration!=expected||session||!profile_valid((const Profile*)fmt,48000,4))setup.valid=0;
 HRESULT hr=setup_step();if(hr!=S_OK)return hr;return setup.align&&(setup.align==2||!c->number)?AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED:S_OK;
}
static HRESULT STDMETHODCALLTYPE setup_buffer(IAudioClient*self,UINT32*frames){if(!((SetupClient*)self)->initialized)setup.valid=0;HRESULT hr=setup_step();if(hr==S_OK)*frames=setup.frames;return hr;}
static HRESULT STDMETHODCALLTYPE setup_event(IAudioClient*self,HANDLE event){if(!((SetupClient*)self)->initialized||event!=(HANDLE)123)setup.valid=0;return setup_step();}
static HRESULT STDMETHODCALLTYPE setup_service(IAudioClient*self,REFIID iid,void**out){
 if(!((SetupClient*)self)->initialized)setup.valid=0;HRESULT hr=setup_step();if(hr!=S_OK||setup.calls==setup.null_at)return hr;
 if(!memcmp(iid,&expected_render,sizeof(IID))){*out=&setup_render;setup.live_render++;}else if(!memcmp(iid,&expected_clock,sizeof(IID))){*out=&setup_clock;setup.live_clock++;}else setup.valid=0;return S_OK;
}
static HRESULT STDMETHODCALLTYPE setup_frequency(IAudioClock*self,UINT64*frequency){if(self!=&setup_clock)setup.valid=0;HRESULT hr=setup_step();if(hr==S_OK)*frequency=setup.frequency;return hr;}
static void reset_setup(void){memset(&setup,0,sizeof(setup));setup.valid=1;setup.frames=512;setup.frequency=48000;setup.period=80000;setup.minimum=30000;setup.failure=E_FAIL;setup.fail_at=UINT32_MAX;setup.null_at=UINT32_MAX;}
static int setup_tests(void){
 CHECK(sizeof(Stream)==96&&offsetof(Stream,client)==48&&offsetof(Stream,frequency)==72&&offsetof(Stream,period)==88);
 CHECK(CLSIDFromString(L"{1CB9AD4C-DBFA-4C32-B178-C2F568A703B2}",&expected_client)==S_OK&&CLSIDFromString(L"{F294ACFC-3146-4483-A7BF-ADDCA7C260E2}",&expected_render)==S_OK&&CLSIDFromString(L"{CD63314F-3FBA-4A1B-812C-EF96358728E7}",&expected_clock)==S_OK);
 device_table.Activate=setup_activate;setup_table.Release=setup_client_release;setup_table.IsFormatSupported=setup_supported;setup_table.GetDevicePeriod=setup_period;setup_table.Initialize=setup_initialize;setup_table.GetBufferSize=setup_buffer;setup_table.SetEventHandle=setup_event;setup_table.GetService=setup_service;render_table.Release=setup_render_release;clock_table.Release=setup_clock_release;clock_table.GetFrequency=setup_frequency;
 unsigned char*area;size_t body;unsigned char*end=guarded(4096,&area,&body);CHECK(end);Stream*s=(Stream*)(end-96);
 for(unsigned alignment=0;alignment<2;alignment++){
  reset_setup();setup.align=alignment;memset(s,0,96);CHECK(output_exclusive_open(&setup_device,48000,(HANDLE)123,s)==S_OK);unsigned steps=setup.calls;
  CHECK(setup.valid&&setup.activations==1+alignment&&setup.live_client==1&&setup.live_render==1&&setup.live_clock==1&&s->frequency==48000&&s->frames==512&&s->period==(alignment?106667:100000)&&profile_valid(&s->profile,48000,4));
  output_exclusive_close(s);CHECK(setup.valid&&!setup.live_client&&!setup.live_render&&!setup.live_clock&&!memcmp(setup.release_order,alignment?"CKRC":"KRC",alignment?4:3));for(unsigned j=0;j<96;j++)CHECK(((unsigned char*)s)[j]==0);output_exclusive_close(s);checks++;
  /* Every COM call can fail. Both negative errors and unexpected positive
   * statuses must leave the destination and owned-interface counts intact. */
  for(unsigned fail=1;fail<=steps;fail++)for(unsigned positive=0;positive<2;positive++){
   reset_setup();setup.align=alignment;setup.fail_at=fail;setup.failure=positive?2:E_FAIL;
   memset(s,0xa5,96);s->client=NULL;s->render=NULL;s->clock=NULL;Stream before=*s;
   CHECK(output_exclusive_open(&setup_device,48000,(HANDLE)123,s)==(positive?E_UNEXPECTED:E_FAIL));
   CHECK(!memcmp(s,&before,96)&&setup.valid&&!setup.live_client&&!setup.live_render&&!setup.live_clock);checks++;
  }
 }
 for(unsigned invalid=0;invalid<10;invalid++){
  reset_setup();memset(s,0,96);switch(invalid){case 0:setup.frames=0;break;case 1:setup.frames=262145;break;case 2:setup.frequency=0;break;case 3:setup.period=0;break;case 4:setup.minimum=-1;break;case 5:setup.period=2000001;break;case 6:setup.null_at=1;break;case 7:setup.null_at=11;break;case 8:setup.null_at=12;break;case 9:setup.align=2;break;}
  HRESULT hr=output_exclusive_open(&setup_device,48000,(HANDLE)123,s);
  CHECK(hr==(invalid==9?AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED:E_UNEXPECTED));CHECK(setup.valid&&!setup.live_client&&!setup.live_render&&!setup.live_clock);checks++;
 }
 reset_setup();memset(s,0,96);CHECK(output_exclusive_open(NULL,48000,(HANDLE)123,s)==E_INVALIDARG&&output_exclusive_open(&setup_device,7999,(HANDLE)123,s)==E_INVALIDARG&&output_exclusive_open(&setup_device,192001,(HANDLE)123,s)==E_INVALIDARG&&output_exclusive_open(&setup_device,48000,NULL,s)==E_INVALIDARG&&output_exclusive_open(&setup_device,48000,(HANDLE)-1,s)==E_INVALIDARG&&output_exclusive_open(&setup_device,48000,(HANDLE)123,NULL)==E_INVALIDARG&&!setup.calls);checks++;
 s->client=(IAudioClient*)1;CHECK(output_exclusive_open(&setup_device,48000,(HANDLE)123,s)==E_INVALIDARG&&!setup.calls);checks++;s->client=NULL;
 output_exclusive_close(NULL);VirtualFree(area,0,MEM_RELEASE);return 0;
}
int main(int argc,char**argv){
 CHECK(argc==1||(argc==2&&!strcmp(argv[1],"--device-probe")));
 unsigned char*area;size_t body;unsigned char*end=guarded(4096,&area,&body);CHECK(end);Profile*p=(Profile*)(end-48);
 for(unsigned k=0;k<9;k++)for(unsigned r=8000;r<=192000;r+=1+(r/9)){
  memset(p,0xa5,48);CHECK(output_format_make(p,r,k,48)&&profile_valid(p,r,k));checks++;
 }
 for(unsigned cap=0;cap<48;cap++){memset(p,0xa5,48);CHECK(!output_format_make(p,48000,0,cap));for(unsigned i=0;i<48;i++)CHECK(((unsigned char*)p)[i]==0xa5);checks++;}
 const unsigned invalid_rates[]={0,7999,192001,UINT32_MAX};for(unsigned i=0;i<4;i++){CHECK(!output_format_make(p,invalid_rates[i],0,48));checks++;}
 CHECK(!output_format_make(p,48000,9,48)&&!output_format_make(NULL,48000,0,48));checks++;
 table.IsFormatSupported=supported;Mock m={{&table},0,0,S_OK,UINT32_MAX,1};
 for(unsigned k=0;k<9;k++){
  m.calls=0;m.accept=1u<<k;m.valid=1;memset(p,0xa5,48);
  CHECK(output_format_choose(&m.base,48000,p,48)==S_OK&&m.calls==k+1&&m.valid&&profile_valid(p,48000,k));checks++;
 }
 m.calls=0;m.accept=0;memset(p,0xa5,48);
 CHECK(output_format_choose(&m.base,48000,p,48)==AUDCLNT_E_UNSUPPORTED_FORMAT&&m.calls==9);checks++;
 for(unsigned i=0;i<48;i++)CHECK(((unsigned char*)p)[i]==0xa5);
 m.calls=0;m.accept=511;CHECK(output_format_choose(&m.base,48000,p,48)==S_OK&&m.calls==1&&p->kind==0);checks++;
 const HRESULT errors[]={AUDCLNT_E_DEVICE_INVALIDATED,E_FAIL,S_FALSE,2};
 for(unsigned i=0;i<4;i++){
  m.calls=0;m.accept=0;m.error_at=0;m.error=errors[i];memset(p,0xa5,48);
  HRESULT want=i==2?AUDCLNT_E_UNSUPPORTED_FORMAT:i==3?E_UNEXPECTED:errors[i];
  CHECK(output_format_choose(&m.base,48000,p,48)==want&&m.calls==(i==2?9:1));
  for(unsigned j=0;j<48;j++)CHECK(((unsigned char*)p)[j]==0xa5);checks++;
 }
 m.error_at=UINT32_MAX;m.calls=0;CHECK(output_format_choose(&m.base,48000,p,47)==E_INVALIDARG&&!m.calls);checks++;
 VirtualFree(area,0,MEM_RELEASE);
 unsigned char *source_area,*dest_area;size_t source_body,dest_body;
 unsigned char *source_end=guarded(262144*8+64,&source_area,&source_body),*dest_end=guarded(262144*8+64,&dest_area,&dest_body);
 unsigned char *expected=malloc(262144*8);CHECK(source_end&&dest_end&&expected);
 const unsigned counts[]={0,1,2,3,17,31,257,4095,4096,262144};const float volumes[]={0,.5f,1,.001f};
 const uint32_t special[]={0,0x80000000,0x3f800000,0xbf800000,0x3f7fffff,0xbf7fffff,0x7f800000,0xff800000,0x7fc00001,0x7f800001,1,0x80000001,0x37800000,0xb7800000,0x33800000,0xb3800000,0x2f800000,0xaf800000,0x7f7fffff};uint32_t seed=7351;
 for(unsigned k=0;k<9;k++)for(unsigned ci=0;ci<10;ci++)for(unsigned vi=0;vi<4;vi++){
  unsigned n=counts[ci];float*input=(float*)(source_end-n*8);size_t bytes=(size_t)n*width(k)*2;unsigned char*out=dest_end-bytes;
  for(unsigned i=0;i<n*2;i++){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;uint32_t v=i%2?seed:special[(i/2)%19];memcpy(input+i,&v,4);}
  memset(out-64,0xa5,bytes+64);reference(expected,input,n,k,volumes[vi]);
  CHECK(output_format_pack(out,input,n,k,bytes,volumes[vi])&&!memcmp(out,expected,bytes));
  for(unsigned i=0;i<64;i++)CHECK(out[(ptrdiff_t)i-64]==0xa5);checks++;values+=(uint64_t)n*2;
  if(n){memset(out,0xa5,bytes);CHECK(!output_format_pack(out,input,n,k,bytes-1,volumes[vi]));for(size_t i=0;i<bytes;i++)CHECK(out[i]==0xa5);checks++;}
 }
 /* Integer ties/rounding must not depend on a caller's rounding direction.
  * Build the oracle in round-to-nearest, then vary only the assembly call. */
 unsigned original_csr=_mm_getcsr();
 for(unsigned k=0;k<9;k++)if(!floating(k))for(unsigned vi=0;vi<4;vi++){
  unsigned n=4096;float*input=(float*)(source_end-n*8);size_t bytes=(size_t)n*width(k)*2;unsigned char*out=dest_end-bytes;
  _mm_setcsr(original_csr&~0x6000u);reference(expected,input,n,k,volumes[vi]);
  for(unsigned mode=0;mode<4;mode++){
   _mm_setcsr((original_csr&~0x6000u)|(mode<<13));int ok=output_format_pack(out,input,n,k,bytes,volumes[vi])&&!memcmp(out,expected,bytes);_mm_setcsr(original_csr);CHECK(ok);checks++;values+=(uint64_t)n*2;
  }
 }
 const float invalid_volumes[]={-1,2,INFINITY,-INFINITY,NAN};unsigned char*out=dest_end-8;float*input=(float*)(source_end-8);
 for(unsigned i=0;i<5;i++){memset(out,0xa5,8);CHECK(!output_format_pack(out,input,1,0,8,invalid_volumes[i]));for(unsigned j=0;j<8;j++)CHECK(out[j]==0xa5);checks++;}
 CHECK(!output_format_pack(out,input,1,9,8,1)&&!output_format_pack(out,input,262145,0,SIZE_MAX,1));checks++;
 CHECK(!output_format_pack(input,input,1,0,8,1)&&!output_format_pack(NULL,input,1,0,8,1)&&!output_format_pack(out,NULL,1,0,8,1));checks++;
 VirtualFree(source_area,0,MEM_RELEASE);VirtualFree(dest_area,0,MEM_RELEASE);free(expected);
 CHECK(!setup_tests());
 printf("{\"result\":\"passed\",\"checks\":%u,\"sample_values\":%llu,\"formats\":9,\"exclusive_playback\":false",checks,(unsigned long long)values);
 if(argc==2){
  const CLSID cls={0xbcde0395,0xe52f,0x467c,{0x8e,0x3d,0xc4,0x57,0x92,0x91,0x69,0x2e}};
  const IID eid={0xa95664d2,0x9614,0x4f35,{0xa7,0x46,0xde,0x8d,0xb6,0x36,0x17,0xe6}},cid={0x1cb9ad4c,0xdbfa,0x4c32,{0xb1,0x78,0xc2,0xf5,0x68,0xa7,3,0xb2}};
  IMMDeviceEnumerator*enumerator=NULL;IMMDevice*device=NULL;IAudioClient*client=NULL;
  HRESULT init=CoInitializeEx(NULL,COINIT_APARTMENTTHREADED),status=init;
  if(SUCCEEDED(status))status=CoCreateInstance(&cls,NULL,CLSCTX_INPROC_SERVER,&eid,(void**)&enumerator);
  if(SUCCEEDED(status))status=IMMDeviceEnumerator_GetDefaultAudioEndpoint(enumerator,eRender,eConsole,&device);
  if(SUCCEEDED(status))status=IMMDevice_Activate(device,&cid,CLSCTX_INPROC_SERVER,NULL,(void**)&client);
  printf(",\"device_probe_hresult\":\"0x%08lx\",\"device_profiles\":[",(unsigned long)status);
  if(SUCCEEDED(status)){
   const unsigned rates[]={8000,44100,48000,96000,192000};Profile choice;
   for(unsigned i=0;i<5;i++){
    memset(&choice,0,sizeof(choice));HRESULT result=output_format_choose(client,rates[i],&choice,sizeof(choice));
    printf("%s{\"rate\":%u,\"hresult\":\"0x%08lx\",\"kind\":%u,\"bits\":%u,\"valid_bits\":%u}",i?",":"",rates[i],(unsigned long)result,result==S_OK?choice.kind:UINT32_MAX,result==S_OK?choice.format.Format.wBitsPerSample:0,result==S_OK?(choice.kind<5?choice.format.Samples.wValidBitsPerSample:choice.format.Format.wBitsPerSample):0);
   }
  }
  printf("]");if(client)IAudioClient_Release(client);if(device)IMMDevice_Release(device);if(enumerator)IMMDeviceEnumerator_Release(enumerator);if(SUCCEEDED(init))CoUninitialize();
 }
 printf("}\n");return 0;
}
