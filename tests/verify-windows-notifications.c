/* Original test-only MMDevice callback server; never changes system outputs. */
#define COBJMACROS
#include <windows.h>
#include <mmdeviceapi.h>
#include <stdint.h>
#include <stdio.h>
HRESULT output_notifications_start(IMMDeviceEnumerator *, HANDLE);
HRESULT output_notifications_stop(void);
unsigned output_notifications_take(void);
extern IMMNotificationClient output_notification_client;
static const IID notify_iid={0x7991eec9,0x7e89,0x4d85,{0x83,0x90,0x6c,0x70,0x3c,0xec,0x60,0xc0}};
static const CLSID enumerator_class={0xbcde0395,0xe52f,0x467c,{0x8e,0x3d,0xc4,0x57,0x92,0x91,0x69,0x2e}};
static const IID enumerator_iid={0xa95664d2,0x9614,0x4f35,{0xa7,0x46,0xde,0x8d,0xb6,0x36,0x17,0xe6}};
uintptr_t device_chosen;
#define CHECK(x) do{if(!(x)){fprintf(stderr,"Notification assertion %d: %s\n",__LINE__,#x);return 1;}}while(0)
typedef struct {IMMDeviceEnumerator base;LONG refs,registrations,removals;HRESULT fail;IMMNotificationClient *client;} Mock;
static HRESULT STDMETHODCALLTYPE query(IMMDeviceEnumerator*a,REFIID b,void**c){(void)a;(void)b;(void)c;return E_NOINTERFACE;}
static ULONG STDMETHODCALLTYPE retain(IMMDeviceEnumerator*a){return InterlockedIncrement(&((Mock*)a)->refs);}
static ULONG STDMETHODCALLTYPE release(IMMDeviceEnumerator*a){return InterlockedDecrement(&((Mock*)a)->refs);}
static HRESULT STDMETHODCALLTYPE registration(IMMDeviceEnumerator*a,IMMNotificationClient*b){Mock*m=(Mock*)a;m->registrations++;if(FAILED(m->fail))return m->fail;m->client=b;return S_OK;}
static HRESULT STDMETHODCALLTYPE removal(IMMDeviceEnumerator*a,IMMNotificationClient*b){Mock*m=(Mock*)a;if(m->client!=b)return E_INVALIDARG;IMMNotificationClient_OnDefaultDeviceChanged(b,eRender,eConsole,L"during unregister");m->client=NULL;m->removals++;return S_OK;}
static IMMDeviceEnumeratorVtbl table={query,retain,release,NULL,NULL,NULL,registration,removal};
static volatile LONG running;
static DWORD WINAPI fire_thread(void *unused){(void)unused;while(InterlockedCompareExchange(&running,0,0))IMMNotificationClient_OnDefaultDeviceChanged(&output_notification_client,eRender,eConsole,L"mock");return 0;}
int main(void){
 unsigned checks=0;Mock m={{&table},1,0,0,S_OK,NULL};
 CHECK(SUCCEEDED(output_notifications_stop()));checks++;
 HANDLE event=CreateEventW(NULL,FALSE,FALSE,NULL);CHECK(event);
 CHECK(FAILED(output_notifications_start(NULL,event)));checks++;
 CHECK(FAILED(output_notifications_start(&m.base,NULL)));checks++;
 CHECK(SUCCEEDED(output_notifications_start(&m.base,event))&&m.refs==2&&m.client);checks++;
 void *out=NULL;CHECK(SUCCEEDED(IMMNotificationClient_QueryInterface(m.client,&IID_IUnknown,&out))&&out==m.client);checks++;IMMNotificationClient_Release((IMMNotificationClient*)out);
 CHECK(SUCCEEDED(IMMNotificationClient_QueryInterface(m.client,&notify_iid,&out)));checks++;IMMNotificationClient_Release((IMMNotificationClient*)out);
 CHECK(IMMNotificationClient_QueryInterface(m.client,&IID_IDispatch,&out)==E_NOINTERFACE&&out==NULL);checks++;
 CHECK(IMMNotificationClient_QueryInterface(m.client,&IID_IUnknown,NULL)==E_POINTER);checks++;
 for(int flow=0;flow<=2;flow++)for(int role=0;role<=2;role++){
  CHECK(SUCCEEDED(IMMNotificationClient_OnDefaultDeviceChanged(m.client,(EDataFlow)flow,(ERole)role,NULL)));
  DWORD signaled=WaitForSingleObject(event,0);unsigned pending=output_notifications_take();
  CHECK(signaled==((flow==0&&role==0)?WAIT_OBJECT_0:WAIT_TIMEOUT)&&pending==(flow==0&&role==0));checks++;
  CHECK(!output_notifications_take());checks++;
 }
 for(unsigned i=0;i<1000;i++)IMMNotificationClient_OnDefaultDeviceChanged(m.client,eRender,eConsole,L"burst");
 CHECK(output_notifications_take()==1&&!output_notifications_take()&&WaitForSingleObject(event,0)==WAIT_OBJECT_0);checks++;
 device_chosen=1;IMMNotificationClient_OnDefaultDeviceChanged(m.client,eRender,eConsole,L"pinned");
 CHECK(!output_notifications_take()&&WaitForSingleObject(event,0)==WAIT_TIMEOUT);checks++;
 device_chosen=0;IMMNotificationClient_OnDefaultDeviceChanged(m.client,eRender,eConsole,L"pending");device_chosen=1;
 CHECK(!output_notifications_take());checks++;device_chosen=0;WaitForSingleObject(event,0);
 CHECK(SUCCEEDED(output_notifications_stop())&&m.refs==1&&m.client==NULL);checks++;
 IMMNotificationClient_OnDefaultDeviceChanged(&output_notification_client,eRender,eConsole,L"late");
 CHECK(!output_notifications_take()&&WaitForSingleObject(event,0)==WAIT_TIMEOUT);checks++;
 LONG count=m.registrations;device_chosen=1;
 CHECK(output_notifications_start(&m.base,event)==S_FALSE&&m.registrations==count&&m.refs==1);checks++;device_chosen=0;
 m.fail=E_FAIL;CHECK(output_notifications_start(&m.base,event)==E_FAIL&&m.refs==1);checks++;m.fail=S_OK;
 CHECK(!output_notifications_take());checks++;
 CHECK(SUCCEEDED(output_notifications_start(&m.base,event)));checks++;
 CHECK(SUCCEEDED(output_notifications_start(&m.base,event))&&m.refs==2&&m.client);checks++;
 CHECK(SUCCEEDED(output_notifications_stop())&&m.refs==1&&!output_notifications_take()&&WaitForSingleObject(event,0)==WAIT_TIMEOUT);checks++;
 for(unsigned i=0;i<1000;i++){
  CHECK(SUCCEEDED(output_notifications_start(&m.base,event))&&m.refs==2);
  CHECK(SUCCEEDED(output_notifications_stop())&&m.refs==1);
  CHECK(!output_notifications_take());checks+=3;
 }
 running=1;HANDLE thread=CreateThread(NULL,0,fire_thread,NULL,0,NULL);CHECK(thread);
 CloseHandle(event);
 for(unsigned i=0;i<1000;i++){
  event=CreateEventW(NULL,FALSE,FALSE,NULL);CHECK(event);
  CHECK(SUCCEEDED(output_notifications_start(&m.base,event)));
  Sleep(0);
  CHECK(SUCCEEDED(output_notifications_stop())&&m.refs==1);
  /* The callback continues firing against a detached subscription. Neither
     this event nor a newly recycled handle may be signaled after stop. */
  ResetEvent(event);Sleep(0);
  CHECK(WaitForSingleObject(event,0)==WAIT_TIMEOUT&&!output_notifications_take());checks+=3;
  CloseHandle(event);
 }
 InterlockedExchange(&running,0);CHECK(WaitForSingleObject(thread,5000)==WAIT_OBJECT_0);CloseHandle(thread);
 CHECK(m.refs==1&&m.registrations==m.removals+1);checks++;
 CHECK(SUCCEEDED(CoInitializeEx(NULL,COINIT_APARTMENTTHREADED)));
 IMMDeviceEnumerator *real=NULL;CHECK(SUCCEEDED(CoCreateInstance(&enumerator_class,NULL,CLSCTX_INPROC_SERVER,&enumerator_iid,(void**)&real)));
 event=CreateEventW(NULL,FALSE,FALSE,NULL);CHECK(event);
 for(unsigned i=0;i<32;i++){CHECK(SUCCEEDED(output_notifications_start(real,event)));checks++;CHECK(SUCCEEDED(output_notifications_stop()));checks++;}
 CloseHandle(event);IMMDeviceEnumerator_Release(real);CoUninitialize();
 printf("{\"result\":\"passed\",\"checks\":%u,\"lifecycle_cycles\":2000,\"concurrent_teardowns\":1000,\"real_registrations\":32,\"system_output_changed\":false}\n",checks);return 0;
}
