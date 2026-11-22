/* Test-only stereo control/smoothing and full stereo frame oracle. */
#include "lamp-test.h"
#include <math.h>
#include <float.h>
#include "speex/speex.h"
#include "speex/speex_stereo.h"
#include "speex/speex_callbacks.h"
#include "modes.h"
typedef struct {const unsigned char*data;uint32_t bits,pos,error,reserved;} Bits;
LAMP_ABI int spx_stereo_init(void*,unsigned);
LAMP_ABI int spx_stereo_control(void*,unsigned);
LAMP_ABI int spx_stereo_apply(void*,const float*,float*,unsigned,unsigned);
LAMP_ABI int spx_decoder_init(void*,unsigned,unsigned);
LAMP_ABI int spx_decoder_set_channels(void*,unsigned);
LAMP_ABI int spx_decoder_frame(void*,Bits*,float*,unsigned);
static uint64_t checks,words,control_cases,stereo_cases,frames,losses,dtx_frames,mono_frames,rejections;
static unsigned mode_context,quality_context,frame_context;
static uint32_t rng=0x872478ab;
static unsigned next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"line %d mode=%u quality=%u frame=%u: %s\n",__LINE__,mode_context,quality_context,frame_context,#x);exit(1);}}while(0)
static void exact(const float*a,const void*b,unsigned n,const char*what){for(unsigned i=0;i<n;i++){uint32_t x,y;memcpy(&x,a+i,4);memcpy(&y,(const unsigned char*)b+4*i,4);if(x!=y){float f;memcpy(&f,&y,4);fprintf(stderr,"%s word %u reference=%a/%08x assembly=%a/%08x mode=%u quality=%u frame=%u\n",what,i,(double)a[i],x,(double)f,y,mode_context,quality_context,frame_context);exit(1);}CHECK(x==y);}words+=n;}
static Bits reader(SpeexBits*b){Bits r={(unsigned char*)b->chars,(unsigned)b->nbBits,(unsigned)(b->charPtr*8+b->bitPtr),0,0};return r;}
typedef struct {unsigned char*allocation,*data;size_t size,body,page;} Guard;
static Guard guarded(size_t n,int front){SYSTEM_INFO info;GetSystemInfo(&info);size_t page=info.dwPageSize,body=(n+page-1)/page*page;if(!body)body=page;Guard g={0};DWORD old;g.allocation=VirtualAlloc(NULL,body+page*2,MEM_RESERVE|MEM_COMMIT,PAGE_NOACCESS);CHECK(g.allocation&&VirtualProtect(g.allocation+page,body,PAGE_READWRITE,&old));g.data=g.allocation+page+(front?0:body-n);g.size=n;g.body=body;g.page=page;return g;}
static void release(Guard*g){CHECK(VirtualFree(g->allocation,0,MEM_RELEASE));}
static void untouched(const void*p,size_t n){const unsigned char*b=p;for(size_t i=0;i<n;i++)CHECK(b[i]==0xa5);}
static void component(void){
 const unsigned lengths[]={1,2,17,40,80,160,320,640};const float smooth[]={1.f,-0.f,1e-38f,20.f};
 for(unsigned code=0;code<256;code++)for(unsigned variant=0;variant<4;variant++){
  unsigned char arena[6144];SpeexStereoState ref;CHECK(spx_stereo_init(arena,sizeof(arena)));speex_stereo_state_reset(&ref);ref.smooth_left=smooth[variant];ref.smooth_right=smooth[(variant+1)%4];memcpy(arena,&ref,24);SpeexBits packet;speex_bits_init(&packet);speex_bits_pack(&packet,code,8);speex_bits_rewind(&packet);CHECK(!speex_std_stereo_request_handler(&packet,NULL,&ref));CHECK(spx_stereo_control(arena,code));exact((float*)&ref,arena,6,"control state");control_cases++;
  for(unsigned li=0;li<8;li++)for(unsigned alias=0;alias<3;alias++){
   unsigned n=lengths[li];frame_context=code*100+li*3+alias;float storage[2000],expected[1280];float*mono=storage+32,*out=storage+(alias==0?700:alias==1?32:33);for(unsigned i=0;i<n;i++){uint32_t v=i%4==0?0x80000000:i%4==1?1:i%4==2?0x80000001:0;if(variant==1)memcpy(mono+i,&v,4);else mono[i]=((int)(next()%65537)-32768)/16.f;expected[i]=mono[i];}speex_decode_stereo(expected,n,&ref);CHECK(spx_stereo_apply(arena,mono,out,n,2*n)==(int)n);exact(expected,out,n*2,"stereo PCM");exact((float*)&ref,arena,6,"smoothed state");stereo_cases++;
  }speex_bits_destroy(&packet);
 }
}
static void decode(void*ref,SpeexStereoState*st,unsigned char*a,unsigned n,unsigned channels,SpeexBits*p,Bits*b){float expected[1280],actual[1280];memset(expected,0,sizeof(expected));memset(actual,0xa5,sizeof(actual));int dtx=0;if(!p)CHECK(!speex_decoder_ctl(ref,SPEEX_GET_DTX_STATUS,&dtx));CHECK(!speex_decode(ref,p,expected));if(channels==2)speex_decode_stereo(expected,n,st);CHECK(spx_decoder_frame(a,b,actual,n*channels)==(int)n);if(p)CHECK(!b->error&&b->pos==(unsigned)(p->charPtr*8+p->bitPtr));exact(expected,actual,n*channels,"connected PCM");exact((float*)st,a+15872,6,"connected stereo history");for(unsigned i=n*channels*4;i<sizeof(actual);i++)CHECK(((unsigned char*)actual)[i]==0xa5);frames++;if(channels==1)mono_frames++;if(!p){if(dtx)dtx_frames++;else losses++;}}
static void connected(void){
 const SpeexMode*modes[]={&speex_nb_mode,&speex_wb_mode,&speex_uwb_mode};const unsigned groups[]={1,2,5,64};
 for(unsigned mode=0;mode<3;mode++)for(unsigned quality=0;quality<=10;quality++)for(unsigned variation=0;variation<3;variation++){
  mode_context=mode;quality_context=quality;unsigned n=160u<<mode;unsigned char*a=malloc(65536);void*ref=speex_decoder_init(modes[mode]),*enc=speex_encoder_init(modes[mode]);SpeexStereoState st;speex_stereo_state_reset(&st);CHECK(a&&ref&&enc&&spx_decoder_init(a,65536,mode)==(int)n);SpeexCallback cb={SPEEX_INBAND_STEREO,speex_std_stereo_request_handler,&st};CHECK(!speex_decoder_ctl(ref,SPEEX_SET_HANDLER,&cb));int q=quality;CHECK(!speex_encoder_ctl(enc,SPEEX_SET_QUALITY,&q));int on=variation!=0;CHECK(!speex_encoder_ctl(enc,SPEEX_SET_VBR,&on));on=variation==2;CHECK(!speex_encoder_ctl(enc,SPEEX_SET_VAD,&on));CHECK(!speex_encoder_ctl(enc,SPEEX_SET_DTX,&on));unsigned group=groups[(mode+quality+variation)%4],count=group==64?192:120;
  for(unsigned base=0;base<count;base+=group){SpeexBits p;speex_bits_init(&p);for(unsigned j=0;j<group;j++){unsigned frame=base+j;float input[1280];for(unsigned i=0;i<n;i++){double t=(frame*n+i)/(double)(8000u<<mode);float x=(float)(9000*sin(6.283185307179586*287*t)),y=(float)(7000*sin(6.283185307179586*811*t));if(frame%60<20)x=y=0;if(frame%60>=40){x=(int)(next()%20001)-10000;y=(int)(next()%16001)-8000;}input[i*2]=x*(frame%7)*.2f;input[i*2+1]=(frame%3?x:y)*((6-frame%7)*.2f);}if(frame%3){speex_encode_stereo(input,n,&p);}else for(unsigned i=0;i<n;i++)input[i]=.5f*(input[i*2]+input[i*2+1]);if(frame%17==0){speex_bits_pack(&p,14,5);speex_bits_pack(&p,9,4);speex_bits_pack(&p,frame&255,8);}CHECK(speex_encode(enc,input,&p)>=0);}speex_bits_rewind(&p);Bits b=reader(&p);for(unsigned j=0;j<group;j++){frame_context=base+j;unsigned channels=variation==1&&frame_context%19<4?1:2;CHECK(spx_decoder_set_channels(a,channels));if(frame_context%37==0){for(unsigned k=0;k<1+frame_context%8;k++)decode(ref,&st,a,n,channels,NULL,NULL);}decode(ref,&st,a,n,channels,&p,&b);}CHECK(b.pos==(unsigned)p.nbBits);speex_bits_destroy(&p);}
  speex_encoder_destroy(enc);speex_decoder_destroy(ref);free(a);
 }
}
static void protected_cases(void){
 const unsigned lengths[]={1,2,17,40,80,160,320,640};
 for(unsigned front=0;front<2;front++)for(unsigned code=0;code<256;code++){
  unsigned n=lengths[code%8];Guard src=guarded(n*4,front),arena=guarded(6144+32,0),out=guarded(n*8+32,0);float expected[1280];SpeexStereoState ref;speex_stereo_state_reset(&ref);for(unsigned i=0;i<n;i++)((float*)src.data)[i]=expected[i]=((int)(next()%32769)-16384)/32.f;DWORD old;CHECK(VirtualProtect(src.allocation+src.page,src.body,PAGE_READONLY,&old));memset(arena.data,0xa5,arena.size);memset(out.data,0xa5,out.size);CHECK(spx_stereo_init(arena.data+32,6144));SpeexBits p;speex_bits_init(&p);speex_bits_pack(&p,code,8);speex_bits_rewind(&p);CHECK(!speex_std_stereo_request_handler(&p,NULL,&ref)&&spx_stereo_control(arena.data+32,code));speex_decode_stereo(expected,n,&ref);CHECK(spx_stereo_apply(arena.data+32,(float*)src.data,(float*)(out.data+32),n,2*n)==(int)n);exact(expected,out.data+32,n*2,"protected stereo PCM");exact((float*)&ref,arena.data+32,6,"protected stereo history");untouched(arena.data,32);untouched(out.data,32);release(&src);release(&arena);release(&out);speex_bits_destroy(&p);stereo_cases++;
 }
 unsigned char arena[6144],saved[24];float mono[640]={0},out[1280];
 for(unsigned mutation=0;mutation<20;mutation++){
  CHECK(spx_stereo_init(arena,6144));memset(out,0xa5,sizeof(out));memset(mono,0,sizeof(mono));void*state_arg=arena;const float*source=mono;float*output=out;unsigned n=640,cap=1280;
  switch(mutation){case 0:state_arg=NULL;break;case 1:source=NULL;break;case 2:output=NULL;break;case 3:n=0;break;case 4:n=641;break;case 5:cap=1279;break;case 6:source=(float*)arena;break;case 7:output=(float*)arena;break;case 8:source=(float*)(UINTPTR_MAX-16);break;case 9:output=(float*)(UINTPTR_MAX-16);break;case 10:*(float*)arena=0.f;break;case 11:*(float*)(arena+4)=0.f;break;case 12:*(float*)arena=-1.f;break;case 13:*(unsigned*)(arena+8)=0x7fc12345;break;case 14:*(unsigned*)(mono)=0x7f800000;break;case 15:*(unsigned*)(mono)=0x7fc12345;break;case 16:spx_stereo_control(arena,0);mono[0]=FLT_MAX;break;case 17:*(unsigned*)arena=0x7f800000;break;case 18:*(float*)(arena+4)=-.5f;break;case 19:*(unsigned*)(arena+12)=0xff800000;break;}
  memcpy(saved,arena,24);CHECK(!spx_stereo_apply(state_arg,source,output,n,cap));CHECK(!memcmp(saved,arena,24));untouched(out,sizeof(out));rejections++;
 }
 memcpy(saved,arena,24);CHECK(!spx_stereo_control(arena,256)&&!memcmp(saved,arena,24));CHECK(!spx_stereo_control(NULL,0));CHECK(!spx_stereo_control((void*)(UINTPTR_MAX-4),0));memset(arena,0xa5,sizeof(arena));CHECK(!spx_stereo_init(arena,6143));untouched(arena,sizeof(arena));CHECK(!spx_stereo_init(NULL,6144));rejections+=5;
 /* Whole-decoder late stereo failures roll back already decoded mono data.
    Clean control-only packet ends update balance without touching audio. */
 unsigned char*a=malloc(65536),*before=malloc(16384);CHECK(a&&before);unsigned char data[2]={0,0};
 for(unsigned variant=0;variant<4;variant++){CHECK(spx_decoder_init(a,65536,2)==640&&spx_decoder_set_channels(a,2));Bits b={data,5,0,0,0};if(variant==0)*(unsigned*)(a+15872+8)=0x7fc12345;else if(variant==1)*(unsigned*)(a+16364)=3;else if(variant==2)b.bits=1;else b.bits=0;memcpy(before,a,16384);memset(out,0xa5,sizeof(out));int result=spx_decoder_frame(a,&b,out,variant==1?1280:1279);CHECK(result==-1&&!b.pos&&!b.error&&!memcmp(before,a,16384));untouched(out,sizeof(out));rejections++;}
 CHECK(spx_decoder_init(a,65536,2)==640&&spx_decoder_set_channels(a,2));*(unsigned*)(a+15872+8)=0x7fc12345;Bits b={data,5,0,0,0};memcpy(before,a,16384);memset(out,0xa5,sizeof(out));CHECK(spx_decoder_frame(a,&b,out,1280)==-1&&!b.pos&&!b.error&&!memcmp(before,a,16384));untouched(out,sizeof(out));rejections++;
 CHECK(spx_decoder_init(a,65536,2)==640&&spx_decoder_set_channels(a,2));SpeexBits p;speex_bits_init(&p);speex_bits_pack(&p,14,5);speex_bits_pack(&p,9,4);speex_bits_pack(&p,231,8);speex_bits_pack(&p,15,5);speex_bits_rewind(&p);b=reader(&p);SpeexStereoState ref;speex_stereo_state_reset(&ref);speex_bits_advance(&p,9);CHECK(!speex_std_stereo_request_handler(&p,NULL,&ref));CHECK(spx_decoder_frame(a,&b,out,1280)==0&&b.pos==22&&!b.error);exact((float*)&ref,a+15872,6,"control-only end");untouched(out,sizeof(out));speex_bits_destroy(&p);CHECK(!spx_decoder_set_channels(a,0)&&!spx_decoder_set_channels(a,3)&&!spx_decoder_set_channels(NULL,2));rejections+=3;
 CHECK(spx_decoder_init(a,65536,1)==320&&spx_decoder_set_channels(a,2));memcpy(before,a,16384);speex_bits_init(&p);speex_bits_pack(&p,14,5);speex_bits_pack(&p,9,4);speex_bits_pack(&p,255,8);speex_bits_pack(&p,0,5);speex_bits_pack(&p,1,1);speex_bits_pack(&p,3,3);speex_bits_rewind(&p);b=reader(&p);CHECK(spx_decoder_frame(a,&b,out,640)==-1&&!b.pos&&b.error&&!memcmp(before,a,16384));untouched(out,sizeof(out));speex_bits_destroy(&p);rejections++;free(a);free(before);
}
int main(void){component();connected();protected_cases();printf("{\"suite\":\"speex-stereo\",\"checks\":%llu,\"exact_float_words\":%llu,\"controls\":%llu,\"stereo_cases\":%llu,\"frames\":%llu,\"mono_frames\":%llu,\"losses\":%llu,\"dtx_frames\":%llu,\"rejections\":%llu}\n",(unsigned long long)checks,(unsigned long long)words,(unsigned long long)control_cases,(unsigned long long)stereo_cases,(unsigned long long)frames,(unsigned long long)mono_frames,(unsigned long long)losses,(unsigned long long)dtx_frames,(unsigned long long)rejections);return 0;}
