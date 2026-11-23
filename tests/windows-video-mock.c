/* Original fault-injection oracle for assembly COM ownership and bounds. MIT.
   Its D3D11CreateDevice and COM objects replace the driver only in this test. */
#define COBJMACROS
#define CINTERFACE
#include <initguid.h>
#include <windows.h>
#include <d3d11.h>
#include <dxva.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct { void **v; unsigned id,refs; } Object;
typedef struct { const void *pic,*matrix,*bits; UINT bytes,pad; const void *slices; UINT count,pad2; } Frame;
typedef struct { BYTE a[64],ctx[1024],b[64]; } Guarded;
extern HRESULT win_video_open(void*,UINT,UINT);
extern void win_video_close(void*);
extern HRESULT win_video_decode(void*,const Frame*);
extern HRESULT win_video_readback(void*,void*,uint64_t);
static Object objects[8]; static void *tables[8][112];
static unsigned checks,step,fail_at,short_type,null_type,begun,locked,copies,flushes,maps,unmaps;
static unsigned busy_begin,busy_maps,bad_pitch,min_pool,config_count,format_supported;
static BYTE buffers[4][4224],pixels[80*96];
static DXVA_PicParams_H264 pic; static DXVA_Qmatrix_H264 matrix;
static DXVA_Slice_H264_Short slice; static BYTE bits[128]; static Frame frame;
#define CHECK(x) do { ++checks; if(!(x)) { fprintf(stderr,"video-mock line%d step%u fault%u\n",__LINE__,step,fail_at); exit(1); } } while(0)
static HRESULT fault(void) { return ++step==fail_at?E_FAIL:S_OK; }
static void *make(unsigned id) { CHECK(!objects[id].refs); objects[id].refs=1; return &objects[id]; }
static ULONG STDMETHODCALLTYPE release(Object *o) { CHECK(o->refs==1); return --o->refs; }
static HRESULT STDMETHODCALLTYPE query(Object *o,const GUID *iid,void **out) {
    HRESULT hr=fault(); *out=0; CHECK(o->id==0 || o->id==1);
    CHECK(IsEqualGUID(iid,o->id?&IID_ID3D11VideoContext:&IID_ID3D11VideoDevice));
    if(SUCCEEDED(hr))*out=make(o->id?3:2); return hr;
}
HRESULT WINAPI D3D11CreateDevice(IDXGIAdapter *adapter,D3D_DRIVER_TYPE type,HMODULE software,UINT flags,
    const D3D_FEATURE_LEVEL *levels,UINT n,UINT sdk,ID3D11Device **d,D3D_FEATURE_LEVEL *level,ID3D11DeviceContext **c) {
    CHECK(!adapter && type==D3D_DRIVER_TYPE_HARDWARE && !software);
    CHECK(flags==0x820 && !levels && !n && sdk==7);
    *d=make(0); *c=make(1); *level=D3D_FEATURE_LEVEL_11_0; return fault();
}
static HRESULT STDMETHODCALLTYPE check_format(Object *o,const GUID *profile,UINT format,BOOL *supported) {
    CHECK(o->id==2 && IsEqualGUID(profile,&D3D11_DECODER_PROFILE_H264_VLD_NOFGT) && format==DXGI_FORMAT_NV12);
    *supported=format_supported; return fault();
}
static HRESULT STDMETHODCALLTYPE configs(Object *o,const D3D11_VIDEO_DECODER_DESC *d,UINT *n) {
    CHECK(o->id==2 && d->OutputFormat==DXGI_FORMAT_NV12); *n=config_count; return fault();
}
static HRESULT STDMETHODCALLTYPE config(Object *o,const D3D11_VIDEO_DECODER_DESC *d,UINT i,D3D11_VIDEO_DECODER_CONFIG *cfg) {
    GUID no_encrypt={0x1b81bed0,0xa0c7,0x11d3,{0xb9,0x84,0,0xc0,0x4f,0x2e,0x73,0xc5}};
    CHECK(o->id==2 && i==0); memset(cfg,0,sizeof(*cfg));
    cfg->guidConfigBitstreamEncryption=cfg->guidConfigMBcontrolEncryption=cfg->guidConfigResidDiffEncryption=no_encrypt;
    cfg->ConfigBitstreamRaw=2; cfg->ConfigMinRenderTargetBuffCount=(USHORT)min_pool; return fault();
}
static HRESULT STDMETHODCALLTYPE decoder(Object *o,const D3D11_VIDEO_DECODER_DESC *d,const D3D11_VIDEO_DECODER_CONFIG *cfg,void **out) {
    HRESULT hr=fault(); CHECK(o->id==2 && cfg->ConfigBitstreamRaw==2); *out=0;
    if(SUCCEEDED(hr))*out=make(4); return hr;
}
static HRESULT STDMETHODCALLTYPE texture(Object *o,const D3D11_TEXTURE2D_DESC *d,const void *initial,void **out) {
    HRESULT hr=fault(); CHECK(o->id==0 && !initial && d->MipLevels==1 && d->Format==DXGI_FORMAT_NV12);
    CHECK(d->SampleDesc.Count==1 && !d->SampleDesc.Quality && !d->MiscFlags);
    CHECK(d->ArraySize==(d->Usage==D3D11_USAGE_STAGING?1:min_pool));
    CHECK(d->BindFlags==(d->Usage==D3D11_USAGE_STAGING?0:D3D11_BIND_DECODER));
    CHECK(d->CPUAccessFlags==(d->Usage==D3D11_USAGE_STAGING?D3D11_CPU_ACCESS_READ:0));
    *out=0; if(SUCCEEDED(hr))*out=make(d->Usage==D3D11_USAGE_STAGING?7:5); return hr;
}
static HRESULT STDMETHODCALLTYPE view(Object *o,Object *resource,const D3D11_VIDEO_DECODER_OUTPUT_VIEW_DESC *d,void **out) {
    HRESULT hr=fault(); CHECK(o->id==2 && resource->id==5 && d->ViewDimension==1 && !d->Texture2D.ArraySlice);
    CHECK(IsEqualGUID(&d->DecodeProfile,&D3D11_DECODER_PROFILE_H264_VLD_NOFGT)); *out=0;
    if(SUCCEEDED(hr))*out=make(6); return hr;
}
static HRESULT STDMETHODCALLTYPE begin(Object *o,Object *d,Object *v,UINT keys,const void *key) {
    HRESULT hr=fault(); CHECK(o->id==3 && d->id==4 && v->id==6 && !keys && !key && !begun);
    if(busy_begin) { --busy_begin; return E_PENDING; } if(SUCCEEDED(hr))begun=1; return hr;
}
static HRESULT STDMETHODCALLTYPE end(Object *o,Object *d) { CHECK(o->id==3 && d->id==4 && begun && !locked); begun=0; return fault(); }
static unsigned buffer_index(UINT type) { CHECK(type==0 || type==4 || type==6 || type==5); return type==0?0:type==4?1:type==6?2:3; }
static HRESULT STDMETHODCALLTYPE get_buffer(Object *o,Object *d,UINT type,UINT *size,void **out) {
    HRESULT hr=fault(); unsigned i=buffer_index(type);
    CHECK(o->id==3 && d->id==4 && begun && !locked); *out=0; *size=0;
    if(FAILED(hr))return hr;
    locked=type+1; *size=4096; *out=buffers[i]+64;
    if(short_type==type+1)*size=1; if(null_type==type+1)*out=0; return hr;
}
static HRESULT STDMETHODCALLTYPE release_buffer(Object *o,Object *d,UINT type) {
    CHECK(o->id==3 && d->id==4 && locked==type+1); locked=0; return fault();
}
static HRESULT STDMETHODCALLTYPE submit(Object *o,Object *d,UINT n,const D3D11_VIDEO_DECODER_BUFFER_DESC *desc) {
    const void *data[]={&pic,&matrix,bits,&slice}; const UINT types[]={0,4,6,5},sizes[]={1040,224,128,10}; unsigned i,j;
    CHECK(o->id==3 && d->id==4 && begun && !locked && n==4);
    for(i=0;i<4;++i) {
        D3D11_VIDEO_DECODER_BUFFER_DESC want={0}; want.BufferType=types[i]; want.DataSize=sizes[i];
        if(i>=2)want.NumMBsInBuffer=16;
        CHECK(!memcmp(&want,&desc[i],sizeof(want))); CHECK(!memcmp(buffers[i]+64,data[i],sizes[i]));
        for(j=0;j<64;++j) { CHECK(buffers[i][j]==0xcd); CHECK(buffers[i][4160+j]==0xcd); }
        for(j=64+sizes[i];j<4160;++j) CHECK(buffers[i][j]==0xcd);
    }
    return fault();
}
static void STDMETHODCALLTYPE copy(Object *o,Object *dst,UINT sub,UINT x,UINT y,UINT z,Object *src,UINT source_sub,const void *box) {
    CHECK(o->id==1 && dst->id==7 && src->id==5 && !sub && !x && !y && !z && !source_sub && !box); ++copies;
}
static void STDMETHODCALLTYPE flush(Object *o) { CHECK(o->id==1); ++flushes; }
static HRESULT STDMETHODCALLTYPE map(Object *o,Object *r,UINT sub,UINT type,UINT flags,D3D11_MAPPED_SUBRESOURCE *m) {
    HRESULT hr=fault(); CHECK(o->id==1 && r->id==7 && !sub && type==D3D11_MAP_READ && flags==D3D11_MAP_FLAG_DO_NOT_WAIT);
    ++maps; if(FAILED(hr))return hr; if(busy_maps) { --busy_maps; return DXGI_ERROR_WAS_STILL_DRAWING; }
    m->pData=bad_pitch==3?0:pixels; m->RowPitch=bad_pitch==1?63:bad_pitch==2?65537:80; m->DepthPitch=sizeof(pixels); return S_OK;
}
static void STDMETHODCALLTYPE unmap(Object *o,Object *r,UINT sub) { CHECK(o->id==1 && r->id==7 && !sub); ++unmaps; }
static void reset(Guarded *g) {
    unsigned i,j;
    memset(g,0xa5,sizeof(*g)); memset(g->ctx,0,sizeof(g->ctx)); memset(objects,0,sizeof(objects)); memset(tables,0,sizeof(tables));
    memset(buffers,0xcd,sizeof(buffers));
    for(i=0;i<8;++i) { objects[i].v=tables[i]; objects[i].id=i; tables[i][0]=query; tables[i][2]=release; }
    tables[0][5]=texture; tables[2][3]=decoder; tables[2][7]=view;
    tables[2][13]=check_format; tables[2][14]=configs; tables[2][15]=config;
    tables[3][7]=get_buffer; tables[3][8]=release_buffer; tables[3][9]=begin; tables[3][10]=end; tables[3][11]=submit;
    tables[1][14]=map; tables[1][15]=unmap; tables[1][46]=copy; tables[1][111]=flush;
    step=fail_at=short_type=null_type=begun=locked=copies=flushes=maps=unmaps=busy_begin=busy_maps=bad_pitch=0;
    min_pool=3; config_count=format_supported=1;
    memset(&pic,0,sizeof(pic)); pic.wFrameWidthInMbsMinus1=pic.wFrameHeightInMbsMinus1=3;
    pic.wBitFields=0x9850; pic.ContinuationFlag=1; memset(pic.RefFrameList,255,16);
    memset(&matrix,16,sizeof(matrix)); memset(bits,0,sizeof(bits)); bits[2]=1; bits[3]=0x65;
    slice.BSNALunitDataLocation=0; slice.SliceBytesInBuffer=128; slice.wBadSliceChopping=0;
    frame=(Frame){&pic,&matrix,bits,128,0,&slice,1,0};
    memset(pixels,0xfe,sizeof(pixels)); for(i=0;i<96;++i)for(j=0;j<64;++j)pixels[i*80+j]=(BYTE)(i*31+j);
}
static void closed(Guarded *g) {
    unsigned i,j; win_video_close(g->ctx); win_video_close(g->ctx);
    CHECK(!locked && !begun); for(i=0;i<8;++i)CHECK(!objects[i].refs);
    for(i=0;i<1024;++i)CHECK(!g->ctx[i]); for(i=0;i<64;++i)CHECK(g->a[i]==0xa5 && g->b[i]==0xa5);
    for(i=0;i<4;++i)for(j=0;j<64;++j)CHECK(buffers[i][j]==0xcd && buffers[i][4160+j]==0xcd);
}
int main(void) {
    Guarded g; BYTE output[6144+128]; unsigned i,j,total_steps;
    reset(&g); CHECK(SUCCEEDED(win_video_open(g.ctx,64,64))); CHECK(SUCCEEDED(win_video_decode(g.ctx,&frame)));
    memset(output,0xa7,sizeof(output)); CHECK(SUCCEEDED(win_video_readback(g.ctx,output+64,6144)));
    total_steps=step; CHECK(total_steps==22); CHECK(copies==1 && flushes==1 && maps==1 && unmaps==1);
    for(i=0;i<96;++i)for(j=0;j<64;++j)CHECK(output[64+i*64+j]==(BYTE)(i*31+j));
    for(i=0;i<64;++i)CHECK(output[i]==0xa7 && output[6208+i]==0xa7); closed(&g);
    for(i=1;i<=total_steps;++i) {
        HRESULT hr; reset(&g); fail_at=i; memset(output,0xa7,sizeof(output));
        hr=win_video_open(g.ctx,64,64); if(SUCCEEDED(hr))hr=win_video_decode(g.ctx,&frame);
        if(SUCCEEDED(hr))hr=win_video_readback(g.ctx,output+64,6144); CHECK(FAILED(hr));
        for(j=0;j<sizeof(output);++j)CHECK(output[j]==0xa7); closed(&g);
    }
    for(i=0;i<8;++i) {
        const UINT types[]={0,4,6,5}; reset(&g); CHECK(SUCCEEDED(win_video_open(g.ctx,64,64)));
        if(i<4)short_type=types[i]+1; else null_type=types[i-4]+1;
        CHECK(win_video_decode(g.ctx,&frame)==E_INVALIDARG); CHECK(!locked && !begun); closed(&g);
    }
    reset(&g); CHECK(SUCCEEDED(win_video_open(g.ctx,64,64))); busy_begin=1;
    CHECK(win_video_decode(g.ctx,&frame)==E_PENDING); CHECK(!begun);
    CHECK(SUCCEEDED(win_video_decode(g.ctx,&frame))); busy_maps=3; memset(output,0xa7,sizeof(output));
    for(i=0;i<3;++i) {
        CHECK(win_video_readback(g.ctx,output+64,6144)==E_PENDING); CHECK(win_video_decode(g.ctx,&frame)==E_PENDING);
        CHECK(copies==1 && flushes==1 && !unmaps); for(j=0;j<sizeof(output);++j)CHECK(output[j]==0xa7);
    }
    CHECK(SUCCEEDED(win_video_readback(g.ctx,output+64,6144))); CHECK(copies==1 && flushes==1 && unmaps==1); closed(&g);
    for(i=1;i<=3;++i) {
        reset(&g); CHECK(SUCCEEDED(win_video_open(g.ctx,64,64))); CHECK(SUCCEEDED(win_video_decode(g.ctx,&frame)));
        bad_pitch=i; memset(output,0xa7,sizeof(output)); CHECK(win_video_readback(g.ctx,output+64,6144)==E_INVALIDARG);
        CHECK(unmaps==1); for(j=0;j<sizeof(output);++j)CHECK(output[j]==0xa7); closed(&g);
    }
    for(i=0;i<5;++i) {
        reset(&g); if(i==0)min_pool=0; if(i==1)min_pool=33; if(i==2)config_count=65;
        if(i==3)format_supported=0; if(i==4)min_pool=8;
        CHECK(win_video_open(g.ctx,i==4?4096:64,i==4?4096:64)==DXGI_ERROR_UNSUPPORTED); closed(&g);
    }
    for(i=0;i<14;++i) {
        unsigned before;
        reset(&g); CHECK(SUCCEEDED(win_video_open(g.ctx,64,64))); before=step;
        switch(i) {
        case 0: frame.bytes=127; break;
        case 1: frame.count=0; break;
        case 2: frame.count=257; break;
        case 3: frame.pad=1; break;
        case 4: frame.pad2=1; break;
        case 5: slice.BSNALunitDataLocation=UINT32_MAX; break;
        case 6: slice.SliceBytesInBuffer=UINT32_MAX; break;
        case 7: slice.wBadSliceChopping=1; break;
        case 8: bits[3]=0x61; break;
        case 9: pic.CurrPic.bPicEntry=1; break;
        case 10: pic.bit_depth_luma_minus8=2; break;
        case 11: pic.ContinuationFlag=0; break;
        case 12: pic.RefFrameList[0].bPicEntry=0; break;
        case 13: pic.wFrameWidthInMbsMinus1=4; break;
        }
        CHECK(win_video_decode(g.ctx,&frame)==E_INVALIDARG); CHECK(step==before); closed(&g);
    }
    printf("{\"result\":\"passed\",\"checks\":%u,\"injected_com_failures\":%u,\"short_or_null_driver_buffers\":8,\"bad_mapped_pitches\":3,\"nonblocking_retry_sequences\":1,\"unsupported_configurations\":5,\"invalid_submissions_before_driver\":14}\n",checks,total_steps);
    return 0;
}
