/* Test-only Wine/Windows display observation; no player instrumentation. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
int main(void) {
    HWND window=FindWindowW(L"LampWindow",NULL);RECT rect;
    if(!window||!GetClientRect(window,&rect)||rect.right<64||rect.bottom<64||
       rect.right>2048||rect.bottom>2048)return 1;
    HDC dc=GetDC(window);if(!dc)return 1;
    unsigned red=0,blue=0,green=0,samples=0;
    for(int y=0;y<rect.bottom;y+=8)for(int x=0;x<rect.right;x+=8) {
        COLORREF pixel=GetPixel(dc,x,y);
        if(pixel==CLR_INVALID){ReleaseDC(window,dc);return 1;}
        unsigned r=GetRValue(pixel),g=GetGValue(pixel),b=GetBValue(pixel);
        red+=r>180&&g<50&&b<50;blue+=b>180&&r<50&&g<50;green+=g>100&&r<50&&b<50;samples++;
    }
    ReleaseDC(window,dc);
    printf("{\"red\":%u,\"blue\":%u,\"green\":%u,\"samples\":%u,\"width\":%ld,\"height\":%ld}\n",
           red,blue,green,samples,rect.right,rect.bottom);return 0;
}
