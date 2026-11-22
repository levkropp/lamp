/* Test-only native Win32 output menus and hidden shipping-window lifecycle.
 * Never finds another application's window, sends input or changes defaults. */
#define COBJMACROS
#include <windows.h>
#include <mmdeviceapi.h>
#include <stdint.h>
#include <stdio.h>
#include <wchar.h>

void ui_output_menu_probe(HMENU);
unsigned ui_output_command_probe(unsigned);
void ui_output_capture_probe(void),ui_output_apply_probe(void),ui_output_error_probe(unsigned);
void ui_menu_command_probe(unsigned),ui_device_apply_probe(void),ui_worker_capture_probe(void);
void ui_reopen_at_probe(unsigned,uint64_t),ui_tracks_reset_probe(void),ui_file_opened(void);
const wchar_t*ui_error_title_probe(void),*ui_error_detail_probe(void);
LRESULT CALLBACK ui_window_proc_probe(HWND,UINT,WPARAM,LPARAM);
void engine_pause(void),engine_stop(void);
extern unsigned ui_test_output_exclusive,ui_test_output_error,ui_test_worker_exclusive;
extern int ui_test_output_rate,ui_test_worker_rate,ui_test_track_pending;
extern unsigned ui_test_start_index,ui_test_restart,ui_test_chapter_pending;
extern unsigned ui_test_worker_chapter,ui_test_worker_index;
extern int ui_test_worker_track;
extern uint64_t ui_test_start_ms,ui_test_worker_ms,ui_test_heard_count;
extern unsigned ui_test_device_pending;
extern wchar_t ui_test_device_choice[];
extern const wchar_t**ui_test_paths;
extern HINSTANCE ui_test_instance;
extern HWND ui_test_hwnd;
extern volatile HANDLE ui_thread;
extern volatile unsigned ui_count,ui_state,engine_ready,engine_exclusive,pause_requested,engine_stop_requested,queue_rate;
extern unsigned engine_mode,queue_target,queue_repeat;
extern volatile uint64_t engine_position;
extern void (*engine_opened)(void);
extern IMMNotificationClient output_notification_client;
static unsigned checks;static volatile LONG opened;
static const int rates[]={0,-1,8000,11025,12000,16000,22050,24000,32000,44100,48000,88200,96000,176400,192000};
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"UI-output line %u: %s (state=%u ready=%u mode=%u rate=%u pause=%u opens=%ld thread=%p)\n",__LINE__,#x,ui_state,engine_ready,engine_exclusive,queue_rate,pause_requested,opened,(void*)ui_thread);engine_stop();return 1;}}while(0)

static void pump(void){MSG message;while(PeekMessageW(&message,NULL,0,0,PM_REMOVE)){if(message.message!=WM_QUIT){TranslateMessage(&message);DispatchMessageW(&message);}}}
static void settle(unsigned milliseconds){ULONGLONG end=GetTickCount64()+milliseconds;do{pump();Sleep(5);}while(GetTickCount64()<end);}
static int ready_after(LONG previous,unsigned mode,unsigned rate){ULONGLONG end=GetTickCount64()+5000;do{pump();if(opened>previous&&engine_ready&&engine_exclusive==mode&&queue_rate==rate&&!ui_test_restart&&ui_thread)return 1;if(ui_state==3&&!ui_thread)return 0;Sleep(5);}while(GetTickCount64()<end);return 0;}
static int position_after(uint64_t position){ULONGLONG end=GetTickCount64()+5000;do{pump();if(engine_ready&&engine_position>=position)return 1;if(!ui_thread)return 0;Sleep(5);}while(GetTickCount64()<end);return 0;}
static void file_opened(void){ui_file_opened();InterlockedIncrement(&opened);}
static int menus(unsigned mode,int rate){
 HMENU root=CreatePopupMenu();CHECK(root);ui_output_menu_probe(root);CHECK(GetMenuItemCount(root)==2);
 wchar_t label[100];CHECK(GetMenuStringW(root,0,label,100,MF_BYPOSITION)&&!wcscmp(label,L"Output mode"));CHECK(GetMenuStringW(root,1,label,100,MF_BYPOSITION)&&!wcscmp(label,L"Output sample rate"));
 HMENU modes=GetSubMenu(root,0),sample_rates=GetSubMenu(root,1);CHECK(modes&&sample_rates&&GetMenuItemCount(modes)==2&&GetMenuItemCount(sample_rates)==15);
 for(unsigned i=0;i<2;i++){CHECK(GetMenuItemID(modes,i)==500+i);CHECK((GetMenuState(modes,i,MF_BYPOSITION)&MF_CHECKED)==(i==mode?MF_CHECKED:0));CHECK(GetMenuStringW(modes,i,label,100,MF_BYPOSITION));CHECK(!wcscmp(label,i?L"Exclusive (reserve this output)":L"Shared (other apps can play)"));}
 for(unsigned i=0;i<15;i++){CHECK(GetMenuItemID(sample_rates,i)==520+i);CHECK((GetMenuState(sample_rates,i,MF_BYPOSITION)&MF_CHECKED)==(rates[i]==rate?MF_CHECKED:0));CHECK(GetMenuStringW(sample_rates,i,label,100,MF_BYPOSITION));wchar_t expected[64];if(i<2)wcscpy_s(expected,64,i?L"Device mix rate":L"First opened file");else swprintf_s(expected,64,L"%d Hz",rates[i]);CHECK(!wcscmp(label,expected));}
 CHECK(DestroyMenu(root));return 0;
}
static int unit_checks(void){
 CHECK(ui_test_output_exclusive==0&&ui_test_output_rate==0);
 for(unsigned mode=0;mode<2;mode++)for(unsigned rate=0;rate<15;rate++){
  ui_menu_command_probe(500+mode);ui_menu_command_probe(520+rate);CHECK(ui_test_output_exclusive==mode&&ui_test_output_rate==rates[rate]&&!ui_thread);
  CHECK(!menus(mode,rates[rate]));ui_output_capture_probe();CHECK(ui_test_worker_exclusive==mode&&ui_test_worker_rate==rates[rate]);
  if(rates[rate]>=0){ui_output_apply_probe();CHECK(engine_exclusive==mode&&queue_target==(unsigned)rates[rate]);}
 }
 ui_output_menu_probe(NULL);CHECK(ui_output_command_probe(499)==0&&ui_output_command_probe(502)==0&&ui_output_command_probe(519)==0&&ui_output_command_probe(535)==0&&ui_output_command_probe(UINT32_MAX)==0);
 CHECK(!menus(1,192000));DWORD before=GetGuiResources(GetCurrentProcess(),GR_USEROBJECTS);CHECK(before>0);for(unsigned i=0;i<64;i++)CHECK(!menus(1,192000));CHECK(GetGuiResources(GetCurrentProcess(),GR_USEROBJECTS)==before);

 /* Output choices must not mutate an active worker or unpause it. */
 ui_test_output_exclusive=ui_test_worker_exclusive=engine_exclusive=0;ui_test_output_rate=ui_test_worker_rate=0;queue_target=0;
 ui_thread=(HANDLE)1;ui_count=3;ui_test_heard_count=0;ui_test_start_index=2;ui_test_start_ms=1500;pause_requested=1;ui_test_restart=0;engine_stop_requested=0;
 ui_menu_command_probe(500);CHECK(!ui_test_restart&&!engine_stop_requested&&pause_requested==1);
 ui_menu_command_probe(501);CHECK(ui_test_restart&&engine_stop_requested&&pause_requested==1&&ui_test_start_index==2&&ui_test_start_ms==1500&&engine_exclusive==0&&queue_target==0);
 ui_test_start_index=1;ui_test_start_ms=7000;ui_test_chapter_pending=6;ui_test_track_pending=1;
 for(unsigned i=0;i<1000;i++){ui_menu_command_probe(500+i%2);ui_menu_command_probe(520+i%15);ui_output_capture_probe();CHECK(ui_test_start_index==1&&ui_test_start_ms==7000&&ui_test_chapter_pending==6&&ui_test_track_pending==1&&pause_requested==1&&engine_exclusive==0&&queue_target==0&&ui_test_worker_exclusive==0&&ui_test_worker_rate==0);}
 ui_menu_command_probe(501);ui_menu_command_probe(521);ui_thread=NULL;ui_test_restart=0;ui_worker_capture_probe();CHECK(ui_test_worker_exclusive==1&&ui_test_worker_rate==-1&&ui_test_worker_index==1&&ui_test_worker_ms==7000&&ui_test_worker_chapter==6&&ui_test_worker_track==1);
 ui_test_worker_rate=48000;ui_thread=(HANDLE)1;ui_menu_command_probe(500);ui_menu_command_probe(532);ui_output_apply_probe();CHECK(engine_exclusive==1&&queue_target==48000&&ui_test_worker_rate==48000&&ui_test_output_exclusive==0&&ui_test_output_rate==96000);

 /* Existing Output endpoint changes use the same pause-preserving restart. */
 ui_test_restart=0;engine_stop_requested=0;ui_test_start_index=2;ui_test_start_ms=3500;ui_test_chapter_pending=0;ui_test_track_pending=-1;
 ui_menu_command_probe(200);CHECK(ui_test_device_pending&&ui_test_device_choice[0]==0&&ui_test_restart&&engine_stop_requested&&pause_requested==1&&ui_test_start_index==2&&ui_test_start_ms==3500);
 ui_thread=NULL;ui_test_restart=0;ui_count=0;ui_state=0;ui_device_apply_probe();CHECK(!ui_test_device_pending);
 for(unsigned exclusive=0;exclusive<2;exclusive++){engine_exclusive=exclusive;ui_output_error_probe(3);CHECK(ui_test_output_error==(exclusive?1:2));CHECK(!wcscmp(ui_error_title_probe(),exclusive?L"Exclusive output failed":L"Audio output failed"));CHECK(!wcscmp(ui_error_detail_probe(),exclusive?L"Try Shared mode or another output rate.":L"Choose another output or try again."));ui_output_error_probe(2);CHECK(ui_test_output_error==0&&!wcscmp(ui_error_title_probe(),L"Cannot play this file"));}
 ui_test_chapter_pending=0;ui_test_track_pending=-1;ui_test_heard_count=0;pause_requested=engine_stop_requested=0;ui_test_start_index=0;ui_test_start_ms=0;ui_test_output_exclusive=0;ui_test_output_rate=48000;ui_tracks_reset_probe();
 printf("Hidden native menu/ownership checks passed.\n");fflush(stdout);return 0;
}

static int playback_checks(HWND window,const wchar_t*path,unsigned unsupported_rate){
 const wchar_t*paths[]={path};ui_test_paths=paths;ui_count=1;ui_state=0;ui_test_start_index=0;ui_test_start_ms=0;ui_test_heard_count=0;queue_repeat=0;engine_mode=1;engine_opened=file_opened;
 ui_reopen_at_probe(0,0);CHECK(ready_after(0,0,48000));CHECK(position_after(24000));
 LONG prior=opened;uint64_t position=engine_position;SendMessageW(window,WM_COMMAND,501,0);CHECK(ready_after(prior,1,48000));CHECK(position_after(position));CHECK(pause_requested==0);
 engine_pause();settle(350);CHECK(pause_requested==1);position=engine_position;settle(200);CHECK(engine_position==position);
 prior=opened;SendMessageW(window,WM_COMMAND,500,0);CHECK(ready_after(prior,0,48000)&&pause_requested==1);CHECK(engine_position/48==position/48);position=engine_position;settle(300);CHECK(engine_position==position);
 prior=opened;SendMessageW(window,WM_COMMAND,529,0);CHECK(ready_after(prior,0,44100)&&pause_requested==1);CHECK(engine_position*1000/44100==position/48);position=engine_position;
 prior=opened;SendMessageW(window,WM_COMMAND,530,0);CHECK(ready_after(prior,0,48000)&&pause_requested==1);CHECK(engine_position/48==position*1000/44100);
 prior=opened;SendMessageW(window,WM_COMMAND,521,0);CHECK(ready_after(prior,0,48000)&&pause_requested==1);CHECK(ui_test_output_rate==-1&&ui_test_worker_rate==-1);
 prior=opened;SendMessageW(window,WM_COMMAND,501,0);CHECK(ready_after(prior,1,48000)&&pause_requested==1);
 prior=opened;position=engine_position;SendMessageW(window,WM_COMMAND,200,0);CHECK(ready_after(prior,1,48000)&&pause_requested==1&&engine_position/48==position/48);
 prior=opened;position=engine_position;CHECK(IMMNotificationClient_OnDefaultDeviceChanged(&output_notification_client,eRender,eConsole,NULL)==S_OK);CHECK(ready_after(prior,1,48000)&&pause_requested==1&&engine_position/48==position/48);settle(250);CHECK(engine_position/48==position/48);
 engine_pause();CHECK(position_after(position+24000));prior=opened;CHECK(IMMNotificationClient_OnDefaultDeviceChanged(&output_notification_client,eRender,eConsole,NULL)==S_OK);CHECK(ready_after(prior,1,48000)&&pause_requested==0);position=engine_position;CHECK(position_after(position+12000));
 printf("Hidden shared/exclusive/rate and notification lifecycle passed.\n");fflush(stdout);
 if(unsupported_rate){
  unsigned index=0;while(index<15&&(unsigned)rates[index]!=unsupported_rate)index++;CHECK(index<15);engine_pause();settle(250);position=engine_position;SendMessageW(window,WM_COMMAND,520+index,0);
  ULONGLONG end=GetTickCount64()+5000;while(ui_thread&&GetTickCount64()<end){pump();Sleep(5);}CHECK(!ui_thread&&ui_state==3&&ui_test_output_error==1&&pause_requested==1&&!wcscmp(ui_error_title_probe(),L"Exclusive output failed"));
  prior=opened;SendMessageW(window,WM_COMMAND,530,0);CHECK(ready_after(prior,1,48000)&&pause_requested==1);CHECK(engine_position/48==position/48);settle(200);CHECK(engine_position/48==position/48);
  printf("Unsupported exclusive rate error and paused recovery passed.\n");fflush(stdout);
 }
 CHECK(!IsWindowVisible(window));SendMessageW(window,WM_CLOSE,0,0);ULONGLONG end=GetTickCount64()+5000;while(IsWindow(window)&&GetTickCount64()<end){pump();Sleep(5);}CHECK(!IsWindow(window)&&!ui_thread);return 0;
}

int wmain(int argc,wchar_t**argv){
 CHECK(argc==1||argc==2||argc==3);ui_test_instance=GetModuleHandleW(NULL);WNDCLASSW cls={0};cls.lpfnWndProc=ui_window_proc_probe;cls.hInstance=ui_test_instance;cls.lpszClassName=L"LampHiddenOutputOracle";CHECK(RegisterClassW(&cls));
 HWND window=CreateWindowExW(0,cls.lpszClassName,L"Hidden LAMP output test",WS_OVERLAPPEDWINDOW|WS_CLIPCHILDREN,0,0,820,510,NULL,NULL,ui_test_instance,NULL);CHECK(window&&!IsWindowVisible(window));
 CHECK(!unit_checks());if(argc>1)CHECK(!playback_checks(window,argv[1],argc>2?(unsigned)_wtoi(argv[2]):0));else CHECK(DestroyWindow(window));
 CHECK(UnregisterClassW(cls.lpszClassName,ui_test_instance));printf("{\"result\":\"passed\",\"checks\":%u,\"rapid_staged_changes\":1000,\"rate_choices\":15,\"hidden_window\":true,\"desktop_input\":false,\"system_default_changed\":false,\"native_playback\":%s,\"unsupported_rate\":%u}\n",checks,argc>1?"true":"false",argc>2?(unsigned)_wtoi(argv[2]):0);return 0;
}
