/* Original test-only hidden-window GPU color/crop/aspect/readback oracle. MIT. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
typedef struct { BYTE a[64],ctx[1024],b[64]; } Guard;
typedef struct { BYTE a[64],ctx[16384],b[64]; } Parser;
typedef struct { HWND hwnd; UINT width,height; } Target;
extern int h264_open(void*,const void*,uint64_t,const volatile uint32_t*);
extern int h264_next(void*); extern void h264_close(void*);
extern HRESULT win_video_open(void*,UINT,UINT);
extern HRESULT win_video_open_refs(void*,UINT,UINT,UINT);
extern HRESULT win_video_decode(void*,const void*); extern void win_video_close(void*);
extern HRESULT win_present_open(void*,void*,const void*,const Target*);
extern HRESULT win_present_frame(void*); extern HRESULT win_present_capture(void*,void*,uint64_t);
extern HRESULT win_present_resize(void*,UINT,UINT); extern void win_present_close(void*);
static uint64_t checks,samples,pending,images; static UINT max_error;
#define CHECK(x) do { ++checks; if(!(x)) { fprintf(stderr,"present-oracle line%d\n",__LINE__); exit(1); } } while(0)
static UINT u32(const void *p) { UINT n; memcpy(&n,p,4); return n; }
static void guard(const Guard *g) { UINT i; for(i=0;i<64;++i)CHECK(g->a[i]==0xa5 && g->b[i]==0xa5); }
static BYTE *file(const char *path,size_t *size) {
    FILE *f=fopen(path,"rb"); long n; BYTE *p; CHECK(f!=0); CHECK(!fseek(f,0,SEEK_END)); n=ftell(f); CHECK(n>0); CHECK(!fseek(f,0,SEEK_SET));
    p=malloc(n); CHECK(p!=0); CHECK(fread(p,1,n,f)==(size_t)n); fclose(f); *size=n; return p;
}
static BYTE clip(double value) { int n=(int)floor(value+0.5); return (BYTE)(n<0?0:n>255?255:n); }
static void rgb(const BYTE *ref,UINT w,UINT h,UINT x,UINT y,int full,int matrix,BYTE out[3]) {
    double yy=ref[y*w+x],u=(double)ref[w*h+(y/2)*w+(x&~1u)]-128.0,v=(double)ref[w*h+(y/2)*w+(x&~1u)+1]-128.0;
    double kr=matrix==1?0.2126:0.299,kb=matrix==1?0.0722:0.114,kg=1.0-kr-kb;
    if(!full) { yy=(yy-16)*255.0/219.0;u*=255.0/224.0;v*=255.0/224.0; }
    out[2]=clip(yy+2*(1-kr)*v); out[0]=clip(yy+2*(1-kb)*u);
    out[1]=clip(yy-2*kb*(1-kb)/kg*u-2*kr*(1-kr)/kg*v);
}
static void capture(Guard *p,Parser *h,const BYTE *ref,UINT w,UINT height,const char *output) {
    UINT vw=u32(h->ctx+144),vh=u32(h->ctx+148),sw=u32(h->ctx+228),sh=u32(h->ctx+232),dw,dh,left,top,x,y,i;
    double display,scale; HRESULT hr; uint64_t deadline=GetTickCount64()+5000; size_t bytes=(size_t)w*height*4;
    BYTE *pixels=malloc(bytes+128); FILE *f; CHECK(pixels!=0); memset(pixels,0xa7,bytes+128);
    do { hr=win_present_frame(p->ctx); if(hr==E_PENDING) { ++pending;CHECK(GetTickCount64()<deadline);Sleep(1); } } while(hr==E_PENDING);
    if(FAILED(hr))fprintf(stderr,"frame %08lx\n",hr); CHECK(SUCCEEDED(hr));
    CHECK(win_present_capture(p->ctx,pixels+64,bytes-1)==E_INVALIDARG);
    do { hr=win_present_capture(p->ctx,pixels+64,bytes); if(hr==E_PENDING) { ++pending;CHECK(GetTickCount64()<deadline);Sleep(1); } } while(hr==E_PENDING);
    if(FAILED(hr))fprintf(stderr,"capture %08lx\n",hr); CHECK(SUCCEEDED(hr));
    if(!sw || !sh)sw=sh=1; display=(double)vw*sw/sh; scale=fmin(w/display,(double)height/vh);
    dw=(UINT)floor(display*scale+1e-8);dh=(UINT)floor(vh*scale+1e-8);if(!dw)dw=1;if(!dh)dh=1;
    left=(w-dw)/2;top=(height-dh)/2;
    CHECK(u32(p->ctx+144)==left && u32(p->ctx+148)==top && u32(p->ctx+152)==left+dw && u32(p->ctx+156)==top+dh);
    for(y=0;y<height;++y)for(x=0;x<w;++x) {
        BYTE *q=pixels+64+((size_t)y*w+x)*4; CHECK(q[3]==255);
        if(x<left || x>=left+dw || y<top || y>=top+dh) { CHECK(q[0]==0 && q[1]==0 && q[2]==0); }
    }
    for(y=1;y<10;y+=2)for(x=1;x<10;x+=2) {
        UINT dx=left+(dw-1)*x/10,dy=top+(dh-1)*y/10;
        UINT sx=(UINT)(((double)(dx-left)+0.5)*vw/dw),sy=(UINT)(((double)(dy-top)+0.5)*vh/dh);
        BYTE expected[3],*q=pixels+64+((size_t)dy*w+dx)*4;
        UINT matrix=u32(h->ctx+248); if(matrix==2)matrix=u32(h->ctx+140)>576 || u32(h->ctx+136)>=1280?1:6;
        if(sx>=vw)sx=vw-1;if(sy>=vh)sy=vh-1;
        rgb(ref,vw,vh,sx,sy,u32(h->ctx+236)!=0,matrix==1?1:6,expected);
        for(i=0;i<3;++i) { UINT error=(UINT)abs((int)q[i]-expected[i]);if(error>max_error)max_error=error;
            if(error>3)fprintf(stderr,"RGB x%u y%u channel%u got%u expected%u\n",dx,dy,i,q[i],expected[i]);CHECK(error<=3);++samples; }
    }
    for(i=0;i<64;++i)CHECK(pixels[i]==0xa7 && pixels[bytes+64+i]==0xa7);
    f=fopen(output,"wb"); CHECK(f!=0 && fwrite(pixels+64,1,bytes,f)==bytes); fclose(f);free(pixels);guard(p);
    ++images;
}
static void decode(Guard *gpu,Parser *parser) {
    HRESULT hr;uint64_t deadline=GetTickCount64()+5000;
    do {hr=win_video_decode(gpu->ctx,parser->ctx+328);if(hr==E_PENDING){++pending;CHECK(GetTickCount64()<deadline);Sleep(1);}}while(hr==E_PENDING);
    CHECK(SUCCEEDED(hr));
}
int main(int argc,char **argv) {
    Guard gpu,present; Parser parser; BYTE *data,*ref;size_t bytes,ref_bytes,frame_bytes; Target target; HRESULT hr;UINT i,frames=1;int next;
    CHECK(argc==4);data=file(argv[1],&bytes);ref=file(argv[2],&ref_bytes);
    memset(&gpu,0xa5,sizeof(gpu));memset(gpu.ctx,0,sizeof(gpu.ctx));memset(&present,0xa5,sizeof(present));memset(present.ctx,0,sizeof(present.ctx));
    memset(&parser,0xa5,sizeof(parser));memset(parser.ctx,0,sizeof(parser.ctx));CHECK(h264_open(parser.ctx,data,bytes,0));CHECK(h264_next(parser.ctx)==1);
    frame_bytes=(size_t)u32(parser.ctx+144)*u32(parser.ctx+148)*3/2;CHECK(ref_bytes>=frame_bytes && !(ref_bytes%frame_bytes));
    hr=win_video_open_refs(gpu.ctx,u32(parser.ctx+136),u32(parser.ctx+140),u32(parser.ctx+180));CHECK(SUCCEEDED(hr));decode(&gpu,&parser);
    target.hwnd=CreateWindowExW(0,L"STATIC",L"LAMP presenter oracle",WS_POPUP,0,0,96,96,0,0,GetModuleHandleW(0),0);CHECK(target.hwnd!=0);
    target.width=target.height=96;
    /* Invalid opens must not retain resources; valid ownership survives reopen. */
    target.width=0;CHECK(win_present_open(present.ctx,gpu.ctx,parser.ctx,&target)==E_INVALIDARG);guard(&present);target.width=96;
    { UINT old=u32(parser.ctx+244),bad=16;memcpy(parser.ctx+244,&bad,4);
      CHECK(FAILED(win_present_open(present.ctx,gpu.ctx,parser.ctx,&target)));guard(&present);memcpy(parser.ctx+244,&old,4); }
    hr=win_present_open(present.ctx,gpu.ctx,parser.ctx,&target);if(FAILED(hr))fprintf(stderr,"open %08lx\n",hr);CHECK(SUCCEEDED(hr));
    CHECK(FAILED(win_present_open(present.ctx,gpu.ctx,parser.ctx,&target)));CHECK(u32(present.ctx+120)==1);
    CHECK(win_present_capture(present.ctx,0,65536)==E_INVALIDARG);
    CHECK(win_present_resize(present.ctx,4097,96)==E_INVALIDARG);
    capture(&present,&parser,ref,96,96,argv[3]);CHECK(win_present_resize(present.ctx,0,0)==E_INVALIDARG);
    CHECK(SetWindowPos(target.hwnd,0,0,0,161,121,SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE));
    hr=win_present_resize(present.ctx,161,121);if(FAILED(hr))fprintf(stderr,"resize %08lx\n",hr);CHECK(SUCCEEDED(hr));
    capture(&present,&parser,ref,161,121,argv[3]);
    while((next=h264_next(parser.ctx))==1) {
        CHECK((size_t)(frames+1)*frame_bytes<=ref_bytes);decode(&gpu,&parser);
        capture(&present,&parser,ref+frames*frame_bytes,161,121,argv[3]);++frames;
    }
    CHECK(next==0 && (size_t)frames*frame_bytes==ref_bytes);
    win_present_close(present.ctx);win_present_close(present.ctx);guard(&present);for(i=0;i<1024;++i)CHECK(!present.ctx[i]);
    CHECK(DestroyWindow(target.hwnd));win_video_close(gpu.ctx);guard(&gpu);h264_close(parser.ctx);
    for(i=0;i<64;++i)CHECK(parser.a[i]==0xa5 && parser.b[i]==0xa5);free(data);free(ref);
    printf("{\"result\":\"passed\",\"checks\":%llu,\"color_samples\":%llu,\"max_rgb_error\":%u,\"pending_retries\":%llu,\"frames\":%u,\"rendered_images\":%llu}\n",(unsigned long long)checks,(unsigned long long)samples,max_error,(unsigned long long)pending,frames,(unsigned long long)images);return 0;
}
