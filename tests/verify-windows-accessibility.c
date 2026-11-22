/* Original native Windows control test. Hidden windows; no desktop input. */
#define COBJMACROS
#include <windows.h>
#include <commctrl.h>
#include <oleacc.h>
#include <stdio.h>
#include <wchar.h>
HRESULT control_access_name(HWND control, const wchar_t *name);
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"Assertion failed at %d: %s\n",__LINE__,#x); return 1; } } while(0)
static int name_is(HWND control,const wchar_t *expected){
 IAccessible *accessible=NULL;VARIANT self;VariantInit(&self);self.vt=VT_I4;self.lVal=CHILDID_SELF;
 if(FAILED(AccessibleObjectFromWindow(control,OBJID_CLIENT,&IID_IAccessible,(void**)&accessible)))return 0;
 BSTR value=NULL;HRESULT status=IAccessible_get_accName(accessible,self,&value);
 int equal=SUCCEEDED(status)&&value&&!wcscmp(value,expected);SysFreeString(value);IAccessible_Release(accessible);return equal;
}
int main(void){
 INITCOMMONCONTROLSEX common={sizeof(common),ICC_BAR_CLASSES};CHECK(InitCommonControlsEx(&common));
 unsigned checks=0,repeated_clear_invalidarg=0;
 CHECK(FAILED(control_access_name(NULL,L"invalid")));checks++;
 // No caller apartment: the helper must leave the thread uninitialized.
 HWND initial=CreateWindowExW(0,TRACKBAR_CLASSW,L"",WS_POPUP|TBS_NOTICKS,0,0,80,20,NULL,NULL,NULL,NULL);CHECK(initial);
 CHECK(SUCCEEDED(control_access_name(initial,L"Standalone")));checks++;
 APTTYPE initial_type;APTTYPEQUALIFIER initial_qualifier;
 CHECK(CoGetApartmentType(&initial_type,&initial_qualifier)==CO_E_NOTINITIALIZED);checks++;
 CHECK(SUCCEEDED(CoInitializeEx(NULL,COINIT_APARTMENTTHREADED)));
 CHECK(name_is(initial,L"Standalone")&&SUCCEEDED(control_access_name(initial,NULL)));checks++;
 CoUninitialize();CHECK(DestroyWindow(initial));
 for(unsigned mode=0;mode<2;mode++){
  CHECK(SUCCEEDED(CoInitializeEx(NULL,mode?COINIT_MULTITHREADED:COINIT_APARTMENTTHREADED)));
  for(unsigned cycle=0;cycle<16;cycle++){
   HWND parent=CreateWindowExW(0,L"STATIC",L"LAMP hidden accessibility test",WS_POPUP,0,0,100,100,NULL,NULL,NULL,NULL);CHECK(parent);
   for(unsigned i=0;i<2;i++){
    const wchar_t *label=i?L"Volume":L"Playback position";
    HWND slider=CreateWindowExW(0,TRACKBAR_CLASSW,label,WS_CHILD|TBS_NOTICKS,0,0,80,20,parent,NULL,NULL,NULL);CHECK(slider);
    CHECK(!name_is(slider,label));checks++; /* old window-text-only behavior */
    CHECK(SUCCEEDED(control_access_name(slider,label))&&name_is(slider,label));checks++;
    SendMessageW(slider,TBM_SETRANGEMAX,FALSE,100);SendMessageW(slider,TBM_SETPOS,TRUE,37);
    CHECK(SendMessageW(slider,TBM_GETPOS,0,0)==37&&name_is(slider,label));checks++;
    CHECK(SUCCEEDED(control_access_name(slider,L"Updated \x66f2"))&&name_is(slider,L"Updated \x66f2"));checks++;
    CHECK(SUCCEEDED(control_access_name(slider,NULL))&&!name_is(slider,L"Updated \x66f2"));checks++;
    /* Windows 11 returns E_INVALIDARG here although the SDK documents S_OK.
       Preserve the platform HRESULT; the first clear must succeed above. */
    HRESULT cleared=control_access_name(slider,NULL);CHECK(cleared==S_OK||cleared==E_INVALIDARG);
    repeated_clear_invalidarg+=cleared==E_INVALIDARG;checks++;
    APTTYPE apartment;APTTYPEQUALIFIER qualifier;CHECK(SUCCEEDED(CoGetApartmentType(&apartment,&qualifier)));
    CHECK(apartment==(mode?APTTYPE_MTA:APTTYPE_STA)||(!mode&&apartment==APTTYPE_MAINSTA));checks++;
    CHECK(DestroyWindow(slider));
   }
   CHECK(DestroyWindow(parent));
  }
  CoUninitialize();
 }
 printf("{\"result\":\"passed\",\"checks\":%u,\"apartments\":2,\"control_cycles\":64,\"repeated_clear_invalidarg\":%u,\"desktop_input\":false}\n",checks,repeated_clear_invalidarg);return 0;
}
