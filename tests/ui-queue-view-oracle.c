/* Native Win32 callback and virtual-control contract tests. Original, MIT. */
#include "lamp-test.h"
#include <commctrl.h>
#include <stddef.h>
#include <wchar.h>
_Static_assert(LVFI_STRING==2 && LVFI_PARTIAL==8 && LVFI_WRAP==32, "find flags");
_Static_assert(offsetof(LVITEMW, pszText)==24 && offsetof(LVITEMW,cchTextMax)==32, "LVITEM offsets");
_Static_assert(offsetof(NMLVDISPINFOW,item)==24 && (int)LVN_GETDISPINFOW==-177, "display notification");
_Static_assert(offsetof(NMLVFINDITEMW,lvfi)==32 && offsetof(NMLVFINDITEMW,lvfi.psz)==40 && (int)LVN_ODFINDITEMW==-179, "search notification");
_Static_assert(offsetof(LVCOLUMNW,pszText)==16 && offsetof(LVCOLUMNW,iSubItem)==28, "column offsets");
LAMP_ABI void view_text(LVITEMW *);
LAMP_ABI int view_find(NMLVFINDITEMW *);
LAMP_ABI void view_choose(unsigned,uint64_t);
LAMP_ABI void view_toggle(void),view_clear(void),view_sync(void);
LAMP_ABI void view_reload(unsigned);
LAMP_ABI int view_key(MSG *);
extern const wchar_t **view_paths;
extern uint64_t view_generation,view_list_generation,view_start_ms,ui_thread;
extern unsigned ui_count,view_list_new,view_closing,view_index,view_state,view_start_index,view_shown_index;
extern unsigned pause_requested,engine_ready,view_track_choices[];
extern HWND view_hwnd,view_list;
extern HINSTANCE view_instance;
extern HWND view_main_window;
LAMP_ABI void ui_start(void);
static volatile LONG loop_result;
static unsigned checks;
static DWORD WINAPI drive_loop(void *unused) {
    (void)unused;
    for(unsigned n=0;n<400 && !view_main_window;n++)Sleep(25);
    if(!view_main_window)return 0;
    PostMessageW(view_main_window,WM_KEYDOWN,'L',1);
    for(unsigned n=0;n<200 && !view_list;n++)Sleep(25);
    HWND list=view_list;
    if(list) {
        PostMessageW(list,WM_KEYDOWN,VK_ESCAPE,1);
        /* Wine/Xvfb can take two seconds to deactivate an owned window. */
        for(unsigned n=0;n<200 && view_hwnd;n++)Sleep(25);
        if(!view_hwnd && !view_list)InterlockedExchange(&loop_result,1);
    }
    printf("{\"checks\":%u,\"guarded_text_capacities\":24,\"virtual_rows\":65536,\"keyboard_loop\":%ld,\"result\":\"%s\"}\n",
           checks+1,loop_result,loop_result==1?"passed":"failed");fflush(stdout);
    PostMessageW(view_main_window,WM_CLOSE,0,0);
    return 0;
}
#define REQUIRE(x) do { if(!(x)) {fprintf(stderr,"line %d: %s\n",__LINE__,#x); return 1;} checks++; }while(0)
static void pump(void) { MSG m; while(PeekMessageW(&m,NULL,0,0,PM_REMOVE)) {TranslateMessage(&m);DispatchMessageW(&m);} }
static const wchar_t *paths[]={L"Z:\\music\\alpha.flac",L"Z:\\music\\\u00dcber \u6f22\U0001f3b5.flac",L"Z:\\other\\alpha.flac",L"Z:\\music\\zeta.flac"};
static int text(unsigned row,unsigned sub,wchar_t *dst,int capacity) {
    LVITEMW item={.mask=LVIF_TEXT,.iItem=(int)row,.iSubItem=(int)sub,.pszText=dst,.cchTextMax=capacity};
    view_text(&item);return 0;
}
static int find(int start,unsigned flags,const wchar_t *query) {
    NMLVFINDITEMW n={.iStart=start,.lvfi={.flags=flags,.psz=query}};return view_find(&n);
}
int lamp_main(int argc,lamp_char **argv) {
    (void)argc;(void)argv;
    view_paths=paths;ui_count=4;view_generation=view_list_generation=73;view_index=1;view_state=2;
    wchar_t buffer[256];
    text(1,0,buffer,256);REQUIRE(!wcscmp(buffer,L"2"));
    text(1,1,buffer,256);REQUIRE(!wcscmp(buffer,L"\u00dcber \u6f22\U0001f3b5.flac"));
    text(1,2,buffer,256);REQUIRE(!wcscmp(buffer,L"Paused"));
    text(1,3,buffer,256);REQUIRE(!wcscmp(buffer,paths[1]));
    text(0,2,buffer,256);REQUIRE(!*buffer);
    for(unsigned state=0;state<5;state++) {
        const wchar_t *names[]={L"Loading",L"Playing",L"Paused",L"Finished",L"Error"};
        view_state=state;text(1,2,buffer,256);REQUIRE(!wcscmp(buffer,names[state]));
    }
    text(-1,0,buffer,256);REQUIRE(!*buffer);text(4,0,buffer,256);REQUIRE(!*buffer);
    text(0,4,buffer,256);REQUIRE(!*buffer);
    /* Destination ends exactly at an inaccessible page. Sweep every useful
       capacity, including truncation between a UTF-16 surrogate pair. */
    SYSTEM_INFO si;GetSystemInfo(&si);unsigned page=si.dwPageSize;
    unsigned char *memory=VirtualAlloc(NULL,page*2,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);REQUIRE(memory!=NULL);
    DWORD old;REQUIRE(VirtualProtect(memory+page,page,PAGE_NOACCESS,&old));
    const wchar_t *name=L"\u00dcber \u6f22\U0001f3b5.flac";
    for(unsigned n=0;n<24;n++) {
        wchar_t *end=(wchar_t *)(memory+page)-n;
        text(1,1,end,(int)n);
        if(!n) {checks++;continue;}
        unsigned length=(unsigned)wcslen(name);if(length>=n)length=n-1;
        if(length && name[length-1]>=0xd800 && name[length-1]<=0xdbff)length--;
        REQUIRE(wcslen(end)==length && !wmemcmp(end,name,length));
    }
    view_generation++;view_paths=(const wchar_t **)(memory+page);
    text(1,1,buffer,256);REQUIRE(!*buffer);REQUIRE(find(0,LVFI_STRING,L"alpha.flac")==-1);
    view_paths=paths;view_generation=view_list_generation;
    REQUIRE(find(0,LVFI_STRING,L"ALPHA.FLAC")==0);
    REQUIRE(find(1,LVFI_STRING,L"alpha.flac")==2);
    REQUIRE(find(3,LVFI_STRING,L"alpha.flac")==-1);
    REQUIRE(find(3,LVFI_STRING|LVFI_WRAP,L"alpha.flac")==0);
    REQUIRE(find(0,LVFI_PARTIAL,L"\u00fcBER \u6f22\U0001f3b5")==1);
    REQUIRE(find(0,LVFI_STRING,L"alpha")==-1);
    REQUIRE(find(0,LVFI_PARTIAL,L"alpha")==0);
    REQUIRE(find(0,LVFI_PARTIAL,L"alpha.flac.extra")==-1);
    REQUIRE(find(4,LVFI_PARTIAL|LVFI_WRAP,L"z")==3);
    REQUIRE(find(-1,LVFI_PARTIAL,L"z")==3);
    REQUIRE(find(0,LVFI_PARAM,L"z")==-1);
    REQUIRE(find(0,LVFI_PARTIAL,L"")==-1);
    REQUIRE(find(0,LVFI_PARTIAL,NULL)==-1);
    ui_count=0;REQUIRE(find(0,LVFI_PARTIAL|LVFI_WRAP,L"a")==-1);ui_count=4;
    /* Invalid selections cannot mutate a pending launch. Valid ones retain
       pause and per-entry track choices while starting the selected entry. */
    ui_thread=1;view_start_index=3;view_start_ms=9000;pause_requested=1;view_track_choices[1]=3;
    view_choose(1,72);REQUIRE(view_start_index==3 && view_start_ms==9000);
    view_choose(-1,73);REQUIRE(view_start_index==3);
    view_choose(4,73);REQUIRE(view_start_index==3);
    view_list_new=1;view_choose(1,73);REQUIRE(view_start_index==3);view_list_new=0;
    view_closing=1;view_choose(1,73);REQUIRE(view_start_index==3);view_closing=0;
    view_choose(1,73);REQUIRE(view_start_index==1 && view_start_ms==0 && pause_requested==1 && view_track_choices[1]==3);
    /* The native control holds 65,536 virtual entries; paths remain in our
       list. Query the last row through LVM_GETITEMW, which invokes callbacks. */
    const wchar_t **large=calloc(65536,sizeof(*large));REQUIRE(large!=NULL);
    for(unsigned n=0;n<65536;n++)large[n]=paths[n%4];
    view_paths=large;ui_count=65536;view_instance=GetModuleHandleW(NULL);view_start_index=65535;
    view_shown_index=1;engine_ready=1;view_toggle();pump();
    REQUIRE(view_hwnd && view_list);REQUIRE(SendMessageW(view_list,LVM_GETITEMCOUNT,0,0)==65536);
    REQUIRE(GetWindowLongPtrW(view_list,GWL_STYLE)&LVS_OWNERDATA);
    REQUIRE(SendMessageW(view_list,LVM_GETNEXTITEM,-1,LVNI_SELECTED)==65535);
    LVITEMW item={.mask=LVIF_TEXT,.iItem=65535,.iSubItem=0,.pszText=buffer,.cchTextMax=256};
    REQUIRE(SendMessageW(view_list,LVM_GETITEMW,0,(LPARAM)&item));REQUIRE(!wcscmp(buffer,L"65536"));
    item.iItem=1;item.iSubItem=1;
    REQUIRE(SendMessageW(view_list,LVM_GETITEMW,0,(LPARAM)&item));REQUIRE(!wcscmp(buffer,name));
    item.iSubItem=2;REQUIRE(SendMessageW(view_list,LVM_GETITEMW,0,(LPARAM)&item));REQUIRE(!wcscmp(buffer,L"Paused"));
    view_choose(65535,73);REQUIRE(view_start_index==65535 && pause_requested==1);
    view_clear();REQUIRE(SendMessageW(view_list,LVM_GETITEMCOUNT,0,0)==0);
    free(large);view_paths=paths;ui_count=2;view_list_generation++;view_start_index=0;view_reload(0);pump();
    REQUIRE(SendMessageW(view_list,LVM_GETITEMCOUNT,0,0)==2);
    REQUIRE(SendMessageW(view_list,LVM_GETNEXTITEM,-1,LVNI_SELECTED)==0);
    view_choose(1,73);REQUIRE(view_start_index==0);
    view_toggle();REQUIRE(!view_hwnd && !view_list);
    view_toggle();pump();REQUIRE(view_hwnd && SendMessageW(view_list,LVM_GETITEMCOUNT,0,0)==2);
    MSG key={.hwnd=view_list,.message=WM_KEYDOWN,.wParam=VK_ESCAPE};
    REQUIRE(view_key(&key)==1);REQUIRE(!view_hwnd && !view_list);
    ui_thread=0;VirtualFree(memory,0,MEM_RELEASE);
    ui_count=0;view_paths=NULL;
    HANDLE thread=CreateThread(NULL,0,drive_loop,NULL,0,NULL);REQUIRE(thread!=NULL);
    ui_start(); /* This shipping entry point exits the process after WM_QUIT. */
    return 1; /* ui_start must terminate the process. */
}
