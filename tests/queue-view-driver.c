/* Inspect the shipping queue control through its public Win32 messages.
   LVM_GETITEMW is above WM_USER: marshal its structure/text explicitly into
   the target process, then read back the bounded UTF-16 buffer. MIT. */
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <commctrl.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
static int message(HWND window,UINT code,WPARAM w,LPARAM l,LRESULT *result) {
    /* The Python controller bounds this process to 30 seconds. SendMessageW
       is also used by the existing shipping-player driver for native controls. */
    *result=SendMessageW(window,code,w,l);
    return 1;
}
static void string(const wchar_t *text) {
    char value[4096];int n=WideCharToMultiByte(CP_UTF8,0,text,-1,value,sizeof(value),NULL,NULL);
    putchar('"');
    for(int i=0;i<n-1;i++) {unsigned char c=value[i];if(c=='"'||c=='\\')putchar('\\');
        if(c<32)printf("\\u%04x",c);else putchar(c);}
    putchar('"');
}
int main(int argc,char **argv) {
    SetProcessDpiAwarenessContext((HANDLE)-4);
    HWND parent=FindWindowW(L"LampQueue",NULL);
    if(!parent) {puts("{\"open\":false}");return 0;}
    HWND list=GetDlgItem(parent,120);LRESULT count,selected;
    if(!list || !message(list,LVM_GETITEMCOUNT,0,0,&count) || !message(list,LVM_GETNEXTITEM,-1,LVNI_SELECTED,&selected))return 1;
    RECT client;GetClientRect(parent,&client);
    if(argc<2) {printf("{\"open\":true,\"count\":%lld,\"selected\":%lld,\"dpi\":%u,\"client\":[%ld,%ld],\"columns\":[%lld,%lld,%lld,%lld]}\n",(long long)count,(long long)selected,GetDpiForWindow(parent),client.right,client.bottom,
        (long long)SendMessageW(list,LVM_GETCOLUMNWIDTH,0,0),(long long)SendMessageW(list,LVM_GETCOLUMNWIDTH,1,0),
        (long long)SendMessageW(list,LVM_GETCOLUMNWIDTH,2,0),(long long)SendMessageW(list,LVM_GETCOLUMNWIDTH,3,0));return 0;}
    DWORD pid;GetWindowThreadProcessId(list,&pid);
    HANDLE process=OpenProcess(PROCESS_VM_OPERATION|PROCESS_VM_READ|PROCESS_VM_WRITE,FALSE,pid);
    if(!process){fprintf(stderr,"OpenProcess failed: %lu\n",GetLastError());return 1;}
    void *remote=VirtualAllocEx(process,NULL,4096,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);
    if(!remote){fprintf(stderr,"VirtualAllocEx failed: %lu\n",GetLastError());CloseHandle(process);return 1;}
    int row=atoi(argv[1]),ok=0;LRESULT result;
    if(argc>2) {
        RECT rect={.left=LVIR_BOUNDS};SIZE_T bytes;
        if(!WriteProcessMemory(process,remote,&rect,sizeof(rect),&bytes) ||
           !message(list,LVM_GETITEMRECT,row,(LPARAM)remote,&result) || !result ||
           !ReadProcessMemory(process,remote,&rect,sizeof(rect),&bytes))goto done;
        LPARAM point=MAKELPARAM(90,(rect.top+rect.bottom)/2);
        SetForegroundWindow(parent);SetFocus(list);
        if(!message(list,WM_LBUTTONDOWN,MK_LBUTTON,point,&result) ||
           !message(list,WM_LBUTTONUP,0,point,&result) ||
           !message(list,WM_LBUTTONDBLCLK,MK_LBUTTON,point,&result) ||
           !message(list,WM_LBUTTONUP,0,point,&result))goto done;
        puts("{\"double_click\":true}");ok=1;goto done;
    }
    printf("{\"open\":true,\"count\":%lld,\"selected\":%lld,\"row\":%d,\"columns\":[",(long long)count,(long long)selected,row);
    for(int sub=0;sub<4;sub++) {
        wchar_t buffer[512];SIZE_T bytes;
        LVITEMW item={.mask=LVIF_TEXT,.iItem=row,.iSubItem=sub,.pszText=(wchar_t *)((char *)remote+256),.cchTextMax=512};
        if(!WriteProcessMemory(process,remote,&item,sizeof(item),&bytes) ||
           !message(list,LVM_GETITEMW,0,(LPARAM)remote,&result) || !result ||
           !ReadProcessMemory(process,(char *)remote+256,buffer,sizeof(buffer),&bytes))goto done;
        buffer[511]=0;if(sub)putchar(',');string(buffer);
    }
    puts("]}");ok=1;
done:
    if(!ok)fprintf(stderr,"row %d inspection failed, last error %lu\n",row,GetLastError());
    VirtualFreeEx(process,remote,0,MEM_RELEASE);CloseHandle(process);return ok?0:1;
}
