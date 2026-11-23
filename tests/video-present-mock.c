/* Original test-only COM failure/busy/ownership oracle; no GPU or windows. MIT. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct Object { void **vtable; int owned,live; } Object;
typedef struct { BYTE before[64],ctx[1024],after[64]; } Guard;
typedef struct { HWND hwnd; UINT width,height; } Target;
extern HRESULT win_present_open(void*,void*,const void*,const Target*);
extern HRESULT win_present_frame(void*);extern HRESULT win_present_resize(void*,UINT,UINT);
extern HRESULT win_present_capture(void*,void*,uint64_t);extern void win_present_close(void*);
static void *device[128],*context[128],*video_device[128],*video_context[128],*dxgi[128],*adapter[128],*factory[128],*swap[128],*enumerator[128],*resource[128];
static Object borrowed[5],objects[128];static UINT allocated,released,live,calls,fail_at,blits,copies,queries,presents,maps,unmaps,query_busy,present_busy,map_busy,bad_map;
static BYTE gpu[1024],meta[16384],mapped[80*16];static uint64_t checks;
#define CHECK(x) do {++checks;if(!(x)){fprintf(stderr,"present-mock line%d failure%u calls%u live%u\n",__LINE__,fail_at,calls,live);exit(1);}}while(0)
static HRESULT step(void) { ++calls;return calls==fail_at?E_FAIL:S_OK; }
static ULONG WINAPI release(Object *o) { CHECK(o->owned && o->live);o->live=0;++released;--live;return 0; }
static Object *make(void **vt) { Object *o;CHECK(allocated<128);o=objects+allocated++;o->vtable=vt;o->owned=o->live=1;++live;return o; }
static HRESULT give(void **out,void **vt) { HRESULT hr=step();*out=FAILED(hr)?0:make(vt);return hr; }
static HRESULT WINAPI query(Object *o,const GUID *id,void **out) { (void)o;CHECK(id!=0);return give(out,dxgi); }
static HRESULT WINAPI get_adapter(Object *o,void **out) { (void)o;return give(out,adapter); }
static HRESULT WINAPI parent(Object *o,const GUID *id,void **out) { (void)o;CHECK(id!=0);return give(out,factory); }
static HRESULT WINAPI create_swap(Object *o,void *d,HWND hwnd,const DXGI_SWAP_CHAIN_DESC1 *desc,void *full,void *restrict_output,void **out) {
    (void)o;CHECK(d==borrowed && hwnd==(HWND)1 && desc->BufferCount==2 && desc->Format==DXGI_FORMAT_B8G8R8A8_UNORM && desc->SwapEffect==DXGI_SWAP_EFFECT_FLIP_DISCARD && !full && !restrict_output);
    return give(out,swap);
}
static HRESULT WINAPI association(Object *o,HWND hwnd,UINT flags) {(void)o;CHECK(hwnd==(HWND)1 && flags==2);return step();}
static HRESULT WINAPI create_enum(Object *o,const D3D11_VIDEO_PROCESSOR_CONTENT_DESC *desc,void **out) {(void)o;CHECK(desc->InputWidth==64 && desc->InputHeight==64 && desc->OutputWidth>0);return give(out,enumerator);}
static HRESULT WINAPI format(Object *o,UINT fmt,UINT *flags) {(void)o;CHECK(fmt==103 || fmt==87);*flags=fmt==103?1:2;return step();}
static HRESULT WINAPI caps(Object *o,D3D11_VIDEO_PROCESSOR_CAPS *c) {(void)o;memset(c,0,sizeof(*c));c->DeviceCaps=16;c->MaxInputStreams=c->MaxStreamStates=1;return step();}
static HRESULT WINAPI create_processor(Object *o,void *e,UINT index,void **out) {(void)o;CHECK(e && !index);return give(out,resource);}
static HRESULT WINAPI create_view(Object *o,void *r,void *e,const void *desc,void **out) {(void)o;CHECK(r && e && desc);return give(out,resource);}
static HRESULT WINAPI get_buffer(Object *o,UINT index,const GUID *id,void **out) {(void)o;CHECK(!index && id);return give(out,resource);}
static HRESULT WINAPI create_texture(Object *o,const D3D11_TEXTURE2D_DESC *desc,void *initial,void **out) {(void)o;CHECK(desc->Format==87 && desc->Width>0 && !initial);return give(out,resource);}
static HRESULT WINAPI create_query(Object *o,const D3D11_QUERY_DESC *desc,void **out) {(void)o;CHECK(desc->Query==D3D11_QUERY_EVENT && !desc->MiscFlags);return give(out,resource);}
static void WINAPI noop(Object *o) { CHECK(o!=0); }
static HRESULT WINAPI blit(Object *o,void *processor,void *output,UINT frame,UINT streams,const D3D11_VIDEO_PROCESSOR_STREAM *stream) {
    (void)o;CHECK(processor && output && !frame && streams==1 && stream->Enable && stream->pInputSurface);++blits;return step();
}
static void WINAPI copy(Object *o,void *dest,void *source) {(void)o;CHECK(dest && source);++copies;}
static HRESULT WINAPI get_data(Object *o,void *q,void *dest,UINT size,UINT flags) {(void)o;CHECK(q && !dest && !size && flags==1);++queries;if(query_busy){--query_busy;return S_FALSE;}return step();}
static HRESULT WINAPI present(Object *o,UINT interval,UINT flags) {(void)o;CHECK(!interval && (flags==8 || flags==1));++presents;if(present_busy){--present_busy;return DXGI_ERROR_WAS_STILL_DRAWING;}return step();}
static HRESULT WINAPI resize(Object *o,UINT buffers,UINT width,UINT height,UINT fmt,UINT flags) {(void)o;CHECK(buffers==2 && width && height && fmt==87 && !flags);return step();}
static HRESULT WINAPI map(Object *o,void *r,UINT index,UINT type,UINT flags,D3D11_MAPPED_SUBRESOURCE *m) {
    HRESULT hr;(void)o;CHECK(r && !index && type==1 && flags==0x100000);++maps;if(map_busy){--map_busy;return DXGI_ERROR_WAS_STILL_DRAWING;}
    hr=step();if(FAILED(hr))return hr;m->pData=bad_map==2?0:mapped;m->RowPitch=bad_map==1?63:80;m->DepthPitch=1280;return S_OK;
}
static void WINAPI unmap(Object *o,void *r,UINT index) {(void)o;CHECK(r && !index);++unmaps;}
static void put(UINT offset,uint32_t value) {memcpy(meta+offset,&value,4);}
static void pointer(UINT offset,void *p) {memcpy(gpu+offset,&p,8);}
static void initialize(Guard *g) {
    UINT i;memset(g,0xa5,sizeof(*g));memset(g->ctx,0,1024);memset(gpu,0,1024);memset(meta,0,sizeof(meta));
    allocated=released=live=calls=blits=copies=queries=presents=maps=unmaps=query_busy=present_busy=map_busy=bad_map=0;
    for(i=0;i<5;++i){borrowed[i].owned=borrowed[i].live=0;}
    borrowed[0].vtable=device;borrowed[1].vtable=context;borrowed[2].vtable=video_device;borrowed[3].vtable=video_context;borrowed[4].vtable=resource;
    pointer(0,borrowed);pointer(8,borrowed+1);pointer(16,borrowed+2);pointer(24,borrowed+3);pointer(40,borrowed+4);
    {UINT n=64,one=1;memcpy(gpu+64,&n,4);memcpy(gpu+68,&n,4);memcpy(gpu+72,&one,4);memcpy(gpu+92,&one,4);}
    put(136,64);put(140,64);put(144,64);put(148,64);put(228,1);put(232,1);put(240,1);put(244,1);put(248,1);
}
static void close_check(Guard *g) {
    UINT i;win_present_close(g->ctx);win_present_close(g->ctx);CHECK(!live && allocated==released);
    for(i=0;i<64;++i)CHECK(g->before[i]==0xa5 && g->after[i]==0xa5);
    for(i=0;i<1024;++i)CHECK(g->ctx[i]==0);
}
int main(void) {
    Guard g;Target t={(HWND)1,16,16};UINT i,n,open_calls,resize_calls;BYTE output[64+1024+64];HRESULT hr;
    void **tables[]={device,context,video_device,video_context,dxgi,adapter,factory,swap,enumerator,resource};
    for(i=0;i<10;++i)tables[i][2]=release;
    device[0]=query;device[5]=create_texture;device[24]=create_query;
    dxgi[7]=get_adapter;adapter[6]=parent;factory[15]=create_swap;factory[8]=association;
    video_device[10]=create_enum;video_device[4]=create_processor;video_device[8]=create_view;video_device[9]=create_view;
    enumerator[8]=format;enumerator[9]=caps;swap[9]=get_buffer;swap[8]=present;swap[13]=resize;
    for(i=13;i<=37;++i)video_context[i]=noop;video_context[53]=blit;
    context[47]=copy;context[28]=noop;context[111]=noop;context[29]=get_data;context[14]=map;context[15]=unmap;
    initialize(&g);fail_at=0;CHECK(win_present_open(g.ctx,gpu,meta,&t)==S_OK);open_calls=calls;CHECK(live==11);close_check(&g);
    for(n=1;n<=open_calls;++n){initialize(&g);fail_at=n;CHECK(FAILED(win_present_open(g.ctx,gpu,meta,&t)));close_check(&g);}
    initialize(&g);fail_at=0;CHECK(win_present_open(g.ctx,gpu,meta,&t)==S_OK);query_busy=2;present_busy=2;
    for(i=0;i<4;++i){CHECK(win_present_frame(g.ctx)==E_PENDING);CHECK(win_present_resize(g.ctx,32,32)==E_PENDING);}
    CHECK(win_present_frame(g.ctx)==S_OK);CHECK(blits==1 && copies==1 && queries==5 && presents==3);
    for(i=0;i<sizeof(mapped);++i)mapped[i]=(BYTE)i;
    memset(output,0xa7,sizeof(output));map_busy=2;
    for(i=0;i<2;++i){CHECK(win_present_capture(g.ctx,output+64,1024)==E_PENDING);CHECK(win_present_frame(g.ctx)==E_PENDING);CHECK(win_present_resize(g.ctx,32,32)==E_PENDING);}
    CHECK(win_present_capture(g.ctx,output+64,1024)==S_OK);CHECK(copies==2 && maps==3 && unmaps==1);
    for(i=0;i<16;++i)CHECK(!memcmp(output+64+i*64,mapped+i*80,64));
    for(i=0;i<64;++i)CHECK(output[i]==0xa7 && output[1088+i]==0xa7);close_check(&g);
    for(n=1;n<=2;++n){initialize(&g);fail_at=0;CHECK(win_present_open(g.ctx,gpu,meta,&t)==S_OK);CHECK(win_present_frame(g.ctx)==S_OK);bad_map=n;memset(output,0xa7,sizeof(output));
        CHECK(FAILED(win_present_capture(g.ctx,output+64,1024)));CHECK(unmaps==1);for(i=0;i<sizeof(output);++i)CHECK(output[i]==0xa7);close_check(&g);}
    initialize(&g);fail_at=0;CHECK(win_present_open(g.ctx,gpu,meta,&t)==S_OK);calls=0;CHECK(win_present_resize(g.ctx,32,32)==S_OK);resize_calls=calls;close_check(&g);
    for(n=1;n<=resize_calls;++n){initialize(&g);fail_at=0;CHECK(win_present_open(g.ctx,gpu,meta,&t)==S_OK);calls=0;fail_at=n;hr=win_present_resize(g.ctx,32,32);CHECK(FAILED(hr));CHECK(FAILED(win_present_frame(g.ctx)));close_check(&g);}
    /* Errors during blit/query/Present and capture allocation/copy-map poison until close. */
    for(n=1;n<=3;++n){initialize(&g);fail_at=0;CHECK(win_present_open(g.ctx,gpu,meta,&t)==S_OK);calls=0;fail_at=n;CHECK(FAILED(win_present_frame(g.ctx)));CHECK(FAILED(win_present_frame(g.ctx)));close_check(&g);}
    for(n=1;n<=2;++n){initialize(&g);fail_at=0;CHECK(win_present_open(g.ctx,gpu,meta,&t)==S_OK);CHECK(win_present_frame(g.ctx)==S_OK);calls=0;fail_at=n;CHECK(FAILED(win_present_capture(g.ctx,output+64,1024)));close_check(&g);}
    initialize(&g);fail_at=0;CHECK(win_present_open(g.ctx,gpu,meta,&t)==S_OK);CHECK(win_present_frame(g.ctx)==S_OK);
    {UINT current=1;memcpy(gpu+100,&current,4);}CHECK(win_present_frame(g.ctx)==S_OK);CHECK(blits==2 && copies==2 && released==1);close_check(&g);
    initialize(&g);fail_at=0;CHECK(win_present_open(g.ctx,gpu,meta,&t)==S_OK);CHECK(win_present_frame(g.ctx)==S_OK);
    {UINT current=1;memcpy(gpu+100,&current,4);}calls=0;fail_at=1;CHECK(FAILED(win_present_frame(g.ctx)));close_check(&g);
    printf("{\"result\":\"passed\",\"checks\":%llu,\"open_failures\":%u,\"resize_failures\":%u,\"gpu_failures\":5,\"bad_maps\":2,\"busy_retries\":6}\n",(unsigned long long)checks,open_calls,resize_calls);return 0;
}
