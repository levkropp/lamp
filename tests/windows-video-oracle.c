/* Original test-only D3D11 H.264 submission/readback integration oracle. MIT. */
#define COBJMACROS
#define CINTERFACE
#include <initguid.h>
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <dxva.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const DXVA_PicParams_H264 *picture; const DXVA_Qmatrix_H264 *matrix;
    const unsigned char *bits; uint32_t bytes,reserved;
    const DXVA_Slice_H264_Short *slices; uint32_t count,reserved2;
} Frame;
typedef struct { unsigned char before[64],ctx[1024],after[64]; } Guarded;
extern HRESULT win_video_open(void*,UINT,UINT);
extern void win_video_close(void*);
extern HRESULT win_video_decode(void*,const Frame*);
extern HRESULT win_video_readback(void*,void*,uint64_t);
static uint64_t checks,frames,pending,pending_begins,bytes_compared;
static unsigned file_index,frame_index;
#define CHECK(x) do { ++checks; if(!(x)) { fprintf(stderr,"windows-video line%d file%u frame%u\n",__LINE__,file_index,frame_index); exit(1); } } while(0)
static uint32_t word(const void *p) { uint32_t v; memcpy(&v,p,4); return v; }
static uint32_t read_word(FILE *f) { uint32_t v; CHECK(fread(&v,4,1,f)==1); return v; }
static void guards(const Guarded *g) { unsigned i; for(i=0;i<64;++i) { CHECK(g->before[i]==0xa5); CHECK(g->after[i]==0xa5); } }
static void output_guard(const unsigned char *p,size_t size) {
    unsigned i; for(i=0;i<64;++i) { CHECK(p[i]==0xa7); CHECK(p[size+64+i]==0xa7); }
}
static void adapter(void *ctx) {
    ID3D11Device *d=*(ID3D11Device**)ctx; IDXGIDevice *dx=0; IDXGIAdapter *a=0; DXGI_ADAPTER_DESC desc;
    CHECK(SUCCEEDED(ID3D11Device_QueryInterface(d,&IID_IDXGIDevice,(void**)&dx)));
    CHECK(SUCCEEDED(IDXGIDevice_GetAdapter(dx,&a))); CHECK(SUCCEEDED(IDXGIAdapter_GetDesc(a,&desc)));
    printf("adapter=%ls vendor=%04x device=%04x config=%u pool=%u\n",desc.Description,desc.VendorId,desc.DeviceId,word((char*)ctx+84),word((char*)ctx+80));
    CHECK(desc.VendorId!=0x1414); /* This verification requires a real hardware adapter. */
    IDXGIAdapter_Release(a); IDXGIDevice_Release(dx);
}
static void verify_file(const char *input,const char *reference) {
    FILE *f=fopen(input,"rb"), *ref=fopen(reference,"rb"); Guarded g;
    unsigned w,h,n,i; size_t size; unsigned char *output,*expected;
    CHECK(f && ref); CHECK(read_word(f)==0x31305657); w=read_word(f); h=read_word(f); n=read_word(f);
    CHECK(w>=16 && h>=16 && n>0); size=(size_t)w*h*3/2;
    output=(unsigned char*)malloc(size+128); expected=(unsigned char*)malloc(size); CHECK(output && expected);
    memset(&g,0xa5,sizeof(g)); memset(g.ctx,0,sizeof(g.ctx));
    { HRESULT hr=win_video_open(g.ctx,w,h); if(FAILED(hr))fprintf(stderr,"open hr%08lx\n",hr); CHECK(SUCCEEDED(hr)); }
    if(!file_index) adapter(g.ctx);
    CHECK(win_video_open(g.ctx,w,h)==E_UNEXPECTED);
    memset(output,0xa7,size+128); CHECK(win_video_readback(g.ctx,output+64,size)==E_UNEXPECTED);
    for(i=0;i<size+128;++i) CHECK(output[i]==0xa7);
    for(frame_index=0;frame_index<n;++frame_index) {
        uint32_t length=read_word(f), count=read_word(f); Frame frame; HRESULT hr; uint64_t deadline;
        unsigned char *storage; size_t prefix=sizeof(DXVA_PicParams_H264)+sizeof(DXVA_Qmatrix_H264)+count*sizeof(DXVA_Slice_H264_Short);
        CHECK(length && length<=16777216 && count && count<=256);
        storage=(unsigned char*)malloc(prefix+length); CHECK(storage!=0);
        CHECK(fread(storage,prefix+length,1,f)==1);
        memset(&frame,0,sizeof(frame)); frame.picture=(const DXVA_PicParams_H264*)storage;
        frame.matrix=(const DXVA_Qmatrix_H264*)(storage+sizeof(DXVA_PicParams_H264));
        frame.slices=(const DXVA_Slice_H264_Short*)(storage+sizeof(DXVA_PicParams_H264)+sizeof(DXVA_Qmatrix_H264));
        frame.bits=storage+prefix; frame.bytes=length; frame.count=count;
        { Frame bad=frame; bad.bytes=length-1; CHECK(win_video_decode(g.ctx,&bad)==E_INVALIDARG);
          bad=frame; bad.count=257; CHECK(win_video_decode(g.ctx,&bad)==E_INVALIDARG);
          bad=frame; bad.reserved=1; CHECK(win_video_decode(g.ctx,&bad)==E_INVALIDARG); }
        deadline=GetTickCount64()+5000;
        do {
            hr=win_video_decode(g.ctx,&frame);
            if(hr==E_PENDING) { ++pending_begins; CHECK(GetTickCount64()<deadline); Sleep(1); }
        } while(hr==E_PENDING);
        if(FAILED(hr))fprintf(stderr,"decode hr%08lx ready%u\n",hr,word(g.ctx+72));
        CHECK(SUCCEEDED(hr));
        memset(output,0xa7,size+128);
        CHECK(win_video_readback(g.ctx,output+64,size-1)==E_INVALIDARG);
        deadline=GetTickCount64()+5000;
        do {
            hr=win_video_readback(g.ctx,output+64,size);
            if(hr==E_PENDING) {
                ++pending; CHECK(GetTickCount64()<deadline);
                for(i=0;i<size+128;++i) CHECK(output[i]==0xa7);
                CHECK(win_video_decode(g.ctx,&frame)==E_PENDING); Sleep(1);
            }
        } while(hr==E_PENDING);
        if(FAILED(hr))fprintf(stderr,"readback hr%08lx\n",hr); CHECK(SUCCEEDED(hr));
        CHECK(fread(expected,size,1,ref)==1);
        for(i=0;i<size;++i) {
            if(output[64+i]!=expected[i]) {
                fprintf(stderr,"pixel %u got%u expected%u\n",i,output[64+i],expected[i]); CHECK(0);
            }
        }
        bytes_compared+=size; output_guard(output,size); guards(&g); ++frames; free(storage);
    }
    CHECK(fgetc(f)==EOF && fgetc(ref)==EOF); fclose(f); fclose(ref);
    win_video_close(g.ctx); win_video_close(g.ctx); guards(&g);
    for(i=0;i<sizeof(g.ctx);++i) CHECK(g.ctx[i]==0);
    free(output); free(expected);
}
int main(int argc,char **argv) {
    unsigned i; Guarded g;
    CHECK(argc>=3 && argc%2==1); CHECK(sizeof(Frame)==48); CHECK(sizeof(DXVA_Slice_H264_Short)==10);
    CHECK(sizeof(DXVA_PicParams_H264)==1040); CHECK(sizeof(D3D11_VIDEO_DECODER_BUFFER_DESC)==72);
    memset(&g,0xa5,sizeof(g)); memset(g.ctx,0,sizeof(g.ctx));
    CHECK(win_video_open(g.ctx,0,16)==E_INVALIDARG); CHECK(win_video_open(g.ctx,16,17)==E_INVALIDARG);
    CHECK(win_video_open(g.ctx,8192,16)==E_INVALIDARG); win_video_close(g.ctx); guards(&g);
    for(i=1;i<(unsigned)argc;i+=2) { file_index=(i-1)/2; verify_file(argv[i],argv[i+1]); }
    printf("{\"result\":\"passed\",\"files\":%u,\"frames\":%llu,\"image_bytes_compared\":%llu,\"pending_readbacks\":%llu,\"pending_frame_begins\":%llu,\"checks\":%llu}\n",
        (argc-1)/2,(unsigned long long)frames,(unsigned long long)bytes_compared,(unsigned long long)pending,(unsigned long long)pending_begins,(unsigned long long)checks);
    return 0;
}
