/* Test-only complete synthesis versus unmodified official Speex. */
#include "lamp-test.h"
#include <math.h>
#include <float.h>
#include "speex/speex.h"
#include "speex/speex_stereo.h"
#include "nb_celp.h"
#include "sb_celp.h"
#include "modes.h"
#include "filters.h"
#include "speex-qmf-reference.h"
LAMP_ABI int spx_qmf_init(void*,unsigned);
LAMP_ABI int spx_qmf_synth(void*,const float*,const float*,float*,unsigned,unsigned);
typedef struct {const unsigned char *data;uint32_t bits,pos,error,reserved;} Bits;
LAMP_ABI int spx_decoder_init(void*,unsigned,unsigned);
LAMP_ABI int spx_decoder_set_flags(void*,unsigned);
LAMP_ABI int spx_decoder_frame(void*,Bits*,float*,unsigned);
static uint64_t checks,words,qmf_cases,frames,rejections,loss_frames,dtx_frames,recovery_frames,packets,gain_frames,compatibility_frames;
static unsigned band_context,quality_context,frame_context;
static unsigned mode_masks[3];
static uint32_t rng=0x571243ef;
static char scratch[8192];
static uint32_t next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"line %d band=%u quality=%u frame=%u: %s\n",__LINE__,band_context,quality_context,frame_context,#x);exit(1);}}while(0)
static void exact(const float*a,const void*b,unsigned n,const char*what){for(unsigned i=0;i<n;i++){uint32_t x,y;memcpy(&x,a+i,4);memcpy(&y,(const unsigned char*)b+4*i,4);if(x!=y){float f;memcpy(&f,&y,4);fprintf(stderr,"%s word %u reference=%a/%08x assembly=%a/%08x band=%u quality=%u frame=%u\n",what,i,(double)a[i],x,(double)f,y,band_context,quality_context,frame_context);exit(1);}CHECK(x==y);}words+=n;}
typedef struct {unsigned char*allocation,*data;size_t size,body,page;} Guard;
static Guard guarded(size_t n,int front){SYSTEM_INFO info;GetSystemInfo(&info);size_t page=info.dwPageSize,body=(n+page-1)/page*page;if(!body)body=page;Guard g={0};DWORD old;g.allocation=VirtualAlloc(NULL,body+page*2,MEM_RESERVE|MEM_COMMIT,PAGE_NOACCESS);CHECK(g.allocation&&VirtualProtect(g.allocation+page,body,PAGE_READWRITE,&old));g.data=g.allocation+page+(front?0:body-n);g.size=n;g.body=body;g.page=page;return g;}
static void release(Guard*g){CHECK(VirtualFree(g->allocation,0,MEM_RELEASE));}
static void untouched(const void*p,size_t n){const unsigned char*b=p;for(size_t i=0;i<n;i++)CHECK(b[i]==0xa5);}
static void qmf(void){
 unsigned char arena[6144];float m0[64],m1[64];CHECK(spx_qmf_init(arena,sizeof(arena)));for(unsigned i=0;i<64;i++){m0[i]=((int)(next()%65537)-32768)/64.f;m1[i]=((int)(next()%65537)-32768)/64.f;}memcpy(arena,m0,256);memcpy(arena+256,m1,256);
 for(unsigned trial=0;trial<6400;trial++){unsigned n=4*(1+trial%160);frame_context=trial;float storage[1536],low[320],high[320],expected[640];for(unsigned i=0;i<n;i++)storage[i]=((int)(next()%65537)-32768)/64.f;memcpy(low,storage,n*2);memcpy(high,storage+n/2,n*2);float*out=storage+(trial%3==0?0:trial%3==1?33:640);qmf_synth(low,high,oracle_h0,expected,n,64,m0,m1,scratch);CHECK(spx_qmf_synth(arena,storage,storage+n/2,out,n,n));exact(expected,out,n,"QMF PCM");exact(m0,arena,64,"QMF low history");exact(m1,arena+256,64,"QMF high history");qmf_cases++;}
}
static unsigned u32(const unsigned char*a,unsigned off){unsigned v;memcpy(&v,a+off,4);return v;}
static Bits reader(SpeexBits*b){Bits r={(unsigned char*)b->chars,(unsigned)b->nbBits,(unsigned)(b->charPtr*8+b->bitPtr),0,0};return r;}
static void nb_state(DecState*s,const unsigned char*a){
 CHECK(u32(a,4)==(unsigned)s->first&&u32(a,8)==(unsigned)s->count_lost&&u32(a,12)==(unsigned)s->submodeID&&u32(a,20)==s->seed);
 CHECK(u32(a,24)==(unsigned)s->last_pitch&&u32(a,28)==(unsigned)s->pitch_gain_buf_idx&&u32(a,32)==(unsigned)s->dtx_enabled&&u32(a,36)==(unsigned)s->voc_offset);
 exact(&s->last_ol_gain,a+44,1,"NB global gain");exact(&s->last_pitch_gain,a+48,1,"NB pitch gain");exact(&s->level,a+52,1,"NB level");exact(&s->max_level,a+56,1,"NB max level");exact(&s->min_level,a+60,1,"NB min level");exact(&s->voc_m1,a+64,1,"NB voc m1");exact(&s->voc_m2,a+68,1,"NB voc m2");exact(&s->voc_mean,a+72,1,"NB voc mean");exact(s->old_qlsp,a+80,10,"NB old LSP");exact(s->interp_qlpc,a+128,10,"NB LPC");exact(s->mem_sp,a+176,10,"NB synthesis memory");exact(s->mem_hp,a+224,2,"NB highpass memory");exact(s->pi_gain,a+240,4,"NB pi gain");exact(s->pitch_gain_buf,a+256,3,"NB gain ring");exact(s->excBuf,a+272,500,"NB excitation buffer");mode_masks[0]|=1u<<s->submodeID;
}
static void sb_state(SBDecState*s,const unsigned char*a){CHECK(u32(a,0)==(unsigned)s->first&&u32(a,4)==(unsigned)s->submodeID&&u32(a,8)==s->seed);exact(&s->last_ener,a+12,1,"SB last energy");exact(s->old_qlsp,a+16,8,"SB old LSP");exact(s->interp_qlpc,a+48,8,"SB LPC");exact(s->mem_sp,a+80,16,"SB synthesis memory");exact(s->pi_gain,a+144,4,"SB pi gain");exact(s->exc_rms,a+160,4,"SB RMS");exact(s->excBuf,a+176,s->subframeSize,"SB excitation");exact(s->g0_mem,a+496,64,"SB low QMF history");exact(s->g1_mem,a+752,64,"SB high QMF history");}
static void decode(void*ref,unsigned char*a,float*innovation,unsigned mode,SpeexBits*packet,Bits*b){
 float expected[640],actual[640];memset(expected,0,sizeof(expected));memset(actual,0xa5,sizeof(actual));void*nb=ref;for(unsigned i=mode;i;i--)nb=((SBDecState*)nb)->st_low;int dtx=((DecState*)nb)->dtx_enabled,lost=((DecState*)nb)->count_lost;CHECK(!speex_decode(ref,packet,expected));CHECK(spx_decoder_frame(a,b,actual,160u<<mode)==(int)(160u<<mode));if(b)CHECK(!b->error&&b->pos==(unsigned)(packet->charPtr*8+packet->bitPtr));nb_state((DecState*)nb,a);
 if(mode){SBDecState*wb=mode==1?(SBDecState*)ref:(SBDecState*)((SBDecState*)ref)->st_low;sb_state(wb,a+8192);mode_masks[1]|=1u<<wb->submodeID;exact(innovation,a+(mode==1?8192:12288)+1008,160u<<mode,"outer innovation");if(mode==2){sb_state((SBDecState*)ref,a+12288);mode_masks[2]|=1u<<((SBDecState*)ref)->submodeID;}}
 else exact(innovation,a+2272,160,"NB innovation");exact(expected,actual,160u<<mode,"PCM");frames++;if(!packet){if(dtx)dtx_frames++;else loss_frames++;}else if(lost)recovery_frames++;
}
static void encoded(void){
 const SpeexMode*modes[]={&speex_nb_mode,&speex_wb_mode,&speex_uwb_mode};const unsigned groups[]={1,2,5,64};
 for(unsigned mode=0;mode<3;mode++)for(unsigned flags=0;flags<4;flags++)for(unsigned quality=0;quality<=10;quality++)for(unsigned variation=0;variation<3;variation++){
  band_context=mode;quality_context=quality;unsigned char*a=malloc(65536);float innovation[640]={0};void*ref=speex_decoder_init(modes[mode]);void*enc=speex_encoder_init(modes[mode]);CHECK(a&&ref&&enc&&spx_decoder_init(a,65536,mode)==(int)(160u<<mode)&&spx_decoder_set_flags(a,flags));int on=!!(flags&1);CHECK(!speex_decoder_ctl(ref,SPEEX_SET_ENH,&on));on=!!(flags&2);CHECK(!speex_decoder_ctl(ref,SPEEX_SET_HIGHPASS,&on));CHECK(!speex_decoder_ctl(ref,SPEEX_SET_INNOVATION_SAVE,innovation));int q=quality;CHECK(!speex_encoder_ctl(enc,SPEEX_SET_QUALITY,&q));on=variation!=0;CHECK(!speex_encoder_ctl(enc,SPEEX_SET_VBR,&on));on=variation==2;CHECK(!speex_encoder_ctl(enc,SPEEX_SET_VAD,&on));CHECK(!speex_encoder_ctl(enc,SPEEX_SET_DTX,&on));unsigned group=groups[(mode+quality+variation)%4],count=group==64?256:160,n=160u<<mode;
  for(unsigned base=0;base<count;base+=group){SpeexBits packet;speex_bits_init(&packet);for(unsigned j=0;j<group;j++){float input[1280];unsigned frame=base+j;for(unsigned i=0;i<n;i++){double t=(frame*n+i)/(double)(8000u<<mode);float x=frame%80<24?0.f:frame%80<48?(float)(9000*sin(6.283185307179586*223*t)+2000*sin(6.283185307179586*4611*t)):((int)(next()%24001)-12000)*.4f;input[i*2]=x;input[i*2+1]=.7f*x;}if(variation==1)speex_encode_stereo(input,n,&packet);else for(unsigned i=0;i<n;i++)input[i]=input[i*2];CHECK(speex_encode(enc,input,&packet)>=0);}speex_bits_rewind(&packet);Bits b=reader(&packet);for(unsigned j=0;j<group;j++){frame_context=base+j;void*nb=ref;for(unsigned k=mode;k;k--)nb=((SBDecState*)nb)->st_low;if((base+j)%37==0&&!((DecState*)nb)->dtx_enabled)for(unsigned k=0;k<1+(base+j)%16;k++)decode(ref,a,innovation,mode,NULL,NULL);decode(ref,a,innovation,mode,&packet,&b);if(((DecState*)nb)->dtx_enabled&&variation==2&&j+1==group)for(unsigned k=0;k<3;k++)decode(ref,a,innovation,mode,NULL,NULL);}CHECK(b.pos==(unsigned)packet.nbBits);packets++;speex_bits_destroy(&packet);}
  speex_encoder_destroy(enc);speex_decoder_destroy(ref);free(a);
 }
}
static void high_pack(SpeexBits*b,unsigned mode,unsigned q,unsigned lsp){speex_bits_pack(b,1,1);speex_bits_pack(b,mode,3);if(!mode)return;speex_bits_pack(b,lsp&4095,12);for(unsigned sub=0;sub<4;sub++){speex_bits_pack(b,(q+sub)%(mode==1?32:16),mode==1?5:4);if(mode>=2){unsigned count=mode==2?20:mode==3?40:80;for(unsigned j=0;j<count;j++)speex_bits_pack(b,next()&1,1);}}}
static void gain_sweeps(void){
 const SpeexMode*modes[]={&speex_nb_mode,&speex_wb_mode,&speex_uwb_mode};SpeexBits base;speex_bits_init(&base);void*enc=speex_encoder_init(&speex_nb_mode);int q=8;CHECK(!speex_encoder_ctl(enc,SPEEX_SET_QUALITY,&q));float input[160];for(unsigned i=0;i<160;i++)input[i]=(float)(9000*sin(.08*i));CHECK(speex_encode(enc,input,&base)>=0);
 for(unsigned mode=1;mode<=2;mode++)for(unsigned flags=0;flags<4;flags++)for(unsigned high=1;high<=4;high++)for(unsigned gain=0;gain<(high==1?32u:16u);gain++){
  band_context=mode;quality_context=99;frame_context=high*32+gain;unsigned char*a=malloc(65536);float innovation[640]={0};void*ref=speex_decoder_init(modes[mode]);CHECK(a&&ref&&spx_decoder_init(a,65536,mode)==(int)(160u<<mode)&&spx_decoder_set_flags(a,flags));int on=!!(flags&1);CHECK(!speex_decoder_ctl(ref,SPEEX_SET_ENH,&on));on=!!(flags&2);CHECK(!speex_decoder_ctl(ref,SPEEX_SET_HIGHPASS,&on));CHECK(!speex_decoder_ctl(ref,SPEEX_SET_INNOVATION_SAVE,innovation));SpeexBits packet;speex_bits_init(&packet);for(unsigned i=0;i<(unsigned)base.nbBits;i++)speex_bits_pack(&packet,((unsigned char*)base.chars)[i/8]>>(7-i%8)&1,1);high_pack(&packet,high,gain,gain*117);if(mode==2)high_pack(&packet,1,gain,gain*123);speex_bits_rewind(&packet);Bits b=reader(&packet);decode(ref,a,innovation,mode,&packet,&b);gain_frames++;speex_bits_destroy(&packet);speex_decoder_destroy(ref);free(a);
 }speex_bits_destroy(&base);speex_encoder_destroy(enc);
}
static void compatibility(void){
 const SpeexMode*modes[]={&speex_nb_mode,&speex_wb_mode,&speex_uwb_mode};
 for(unsigned output_mode=0;output_mode<3;output_mode++)for(unsigned flags=0;flags<4;flags++){
  unsigned char*a=malloc(65536);float innovation[640]={0};void*ref=speex_decoder_init(modes[output_mode]);void*enc[3];CHECK(a&&ref&&spx_decoder_init(a,65536,output_mode)==(int)(160u<<output_mode));CHECK(!speex_decoder_ctl(ref,SPEEX_SET_INNOVATION_SAVE,innovation));for(unsigned i=0;i<3;i++)CHECK((enc[i]=speex_encoder_init(modes[i]))!=NULL);
  for(unsigned frame=0;frame<192;frame++){band_context=output_mode;quality_context=98;frame_context=frame;unsigned source_mode=frame/8%3,n=160u<<source_mode;int q=1+frame%10;CHECK(!speex_encoder_ctl(enc[source_mode],SPEEX_SET_QUALITY,&q));int bits_flags=(flags+frame/13)%4;CHECK(spx_decoder_set_flags(a,bits_flags));int on=!!(bits_flags&1);CHECK(!speex_decoder_ctl(ref,SPEEX_SET_ENH,&on));on=!!(bits_flags&2);CHECK(!speex_decoder_ctl(ref,SPEEX_SET_HIGHPASS,&on));SpeexBits packet;speex_bits_init(&packet);float input[640];for(unsigned j=0;j<3;j++){for(unsigned i=0;i<n;i++)input[i]=(float)(5000*sin(((frame*3+j)*n+i)*.083));CHECK(speex_encode(enc[source_mode],input,&packet)>=0);}speex_bits_rewind(&packet);Bits b=reader(&packet);for(unsigned j=0;j<3;j++){decode(ref,a,innovation,output_mode,&packet,&b);compatibility_frames++;}speex_bits_destroy(&packet);}
  for(unsigned i=0;i<3;i++)speex_encoder_destroy(enc[i]);speex_decoder_destroy(ref);free(a);
 }
}
static void guarded_frames(void){
 SpeexBits base;speex_bits_init(&base);void*enc=speex_encoder_init(&speex_nb_mode);int mode=5;CHECK(!speex_encoder_ctl(enc,SPEEX_SET_MODE,&mode));float input[160];for(unsigned i=0;i<160;i++)input[i]=(float)(5000*sin(.07*i));CHECK(speex_encode(enc,input,&base)>=0);unsigned nb_bits=base.nbBits;
 for(unsigned band=1;band<=2;band++)for(unsigned high=1;high<=(band==1?4u:1u);high++){
  band_context=band;quality_context=97;SpeexBits packet;speex_bits_init(&packet);for(unsigned i=0;i<nb_bits;i++)speex_bits_pack(&packet,((unsigned char*)base.chars)[i/8]>>(7-i%8)&1,1);high_pack(&packet,band==1?high:4,15,1024);unsigned wb_end=packet.nbBits;if(band==2)high_pack(&packet,1,31,2048);unsigned full=packet.nbBits,n=160u<<band;
  for(unsigned front=0;front<2;front++)for(unsigned available=0;available<=full;available++){
   frame_context=available;unsigned bytes=(available+7)/8;Guard src=guarded(bytes,front),arena=guarded(65536+32,0),output=guarded(n*4+32,0);memcpy(src.data,packet.chars,bytes);DWORD old;CHECK(VirtualProtect(src.allocation+src.page,src.body,PAGE_READONLY,&old));memset(arena.data,0xa5,arena.size);CHECK(spx_decoder_init(arena.data+32,65536,band)==(int)n);unsigned char saved[16384];memcpy(saved,arena.data+32,sizeof(saved));memset(output.data,0xa5,output.size);Bits b={bytes?src.data:NULL,available,0,0,0};int result=spx_decoder_frame(arena.data+32,&b,(float*)(output.data+32),n);int expected=available<5?0:available==nb_bits||available==full||(band==2&&available==wb_end)?(int)n:-1;CHECK(result==expected);untouched(arena.data,32);untouched(output.data,32);if(result<0){CHECK(!memcmp(saved,arena.data+32,sizeof(saved))&&!b.pos&&b.error);untouched(output.data,output.size);rejections++;}else if(!result){CHECK(!b.pos&&!b.error);untouched(output.data,output.size);rejections++;}else CHECK(b.pos==available&&!b.error);release(&src);release(&arena);release(&output);
  }speex_bits_destroy(&packet);
 }
 for(unsigned band=1;band<=2;band++)for(unsigned invalid=band==1?5:2;invalid<=7;invalid++){
  unsigned char*a=malloc(65536),saved[16384];float output[640];CHECK(a&&spx_decoder_init(a,65536,band)==(int)(160u<<band));memcpy(saved,a,16384);memset(output,0xa5,sizeof(output));SpeexBits packet;speex_bits_init(&packet);for(unsigned j=0;j<nb_bits;j++)speex_bits_pack(&packet,((unsigned char*)base.chars)[j/8]>>(7-j%8)&1,1);if(band==2)high_pack(&packet,3,15,1024);speex_bits_pack(&packet,1,1);speex_bits_pack(&packet,invalid,3);speex_bits_rewind(&packet);Bits b=reader(&packet);CHECK(spx_decoder_frame(a,&b,output,640)==-1&&!b.pos&&!b.error);CHECK(!memcmp(saved,a,16384));untouched(output,sizeof(output));rejections++;speex_bits_destroy(&packet);free(a);
 }speex_bits_destroy(&base);speex_encoder_destroy(enc);
}
static void rejected(void){
 unsigned char*a=malloc(65536),*saved=malloc(16384);CHECK(a&&saved);unsigned char data[128]={0};float output[640];
 for(unsigned mutation=0;mutation<29;mutation++){
  CHECK(spx_decoder_init(a,65536,2)==640);Bits b={data,sizeof(data)*8,0,0,0},before;void*state_arg=a;Bits*bits_arg=&b;float*out_arg=output;unsigned capacity=640;memset(output,0xa5,sizeof(output));
  switch(mutation){case 0:state_arg=NULL;break;case 1:out_arg=NULL;break;case 2:capacity=639;break;case 3:bits_arg=(Bits*)a;break;case 4:out_arg=(float*)a;break;case 5:out_arg=(float*)&b;break;case 6:b.data=a;break;case 7:b.data=(unsigned char*)output;break;case 8:b.data=(unsigned char*)&b;break;case 9:b.data=NULL;break;case 10:b.bits=8388609;break;case 11:b.pos=b.bits+1;break;case 12:b.error=1;break;case 13:*(unsigned*)(a+16376)=0;break;case 14:*(unsigned*)(a+16368)=3;break;case 15:*(unsigned*)(a+16372)=4;break;case 16:*(unsigned*)(a+8192)=2;break;case 17:*(unsigned*)(a+8192+4)=5;break;case 18:*(unsigned*)(a+12288+4)=2;break;case 19:*(unsigned*)(a+12288+12)=0x7fc12345;break;case 20:*(float*)(a+8192+16)=17.f;break;case 21:out_arg=(float*)(UINTPTR_MAX-20);break;case 22:b.data=(unsigned char*)(UINTPTR_MAX-20);break;case 23:*(float*)(a+8192+12)=FLT_MAX;bits_arg=NULL;break;case 24:*(float*)(a+8192+48)=FLT_MAX;*(float*)(a+8192+80)=FLT_MAX;bits_arg=NULL;break;case 25:data[0]=0x2b;*(unsigned*)(a+8192+496)=0x7f800000;break;case 26:*(unsigned*)(a+12288+3564)=0x7f800000;break;case 27:*(unsigned*)(a+8192+16)=0xff800000;break;case 28:*(unsigned*)(a+20)=0;*(unsigned*)(a+12)=9;break;}
  memcpy(saved,a,16384);before=b;CHECK(spx_decoder_frame(state_arg,bits_arg,out_arg,capacity)==-1);CHECK(!memcmp(saved,a,16384)&&!memcmp(&before,&b,sizeof(b)));untouched(output,sizeof(output));rejections++;
 }
 memset(a,0xa5,65536);CHECK(!spx_decoder_init(a,65535,2));untouched(a,65536);CHECK(!spx_decoder_init(a,65536,3));untouched(a,65536);CHECK(!spx_decoder_init(NULL,65536,0));CHECK(!spx_decoder_set_flags(a,0));CHECK(!spx_decoder_set_flags(NULL,0));CHECK(spx_decoder_init(a,65536,2)==640);memcpy(saved,a,16384);CHECK(!spx_decoder_set_flags(a,4)&&!memcmp(saved,a,16384));rejections+=6;free(a);free(saved);
 unsigned char qmf_arena[6144],qmf_saved[512];float low[320],high[320];
 for(unsigned mutation=0;mutation<13;mutation++){
  CHECK(spx_qmf_init(qmf_arena,6144));memset(low,0,sizeof(low));memset(high,0,sizeof(high));memset(output,0xa5,sizeof(output));void*state_arg=qmf_arena;const float*lo=low,*hi=high;float*out_arg=output;unsigned n=640,cap=640;
  switch(mutation){case 0:state_arg=NULL;break;case 1:lo=NULL;break;case 2:hi=NULL;break;case 3:out_arg=NULL;break;case 4:n=0;break;case 5:n=642;break;case 6:n=638;break;case 7:cap=639;break;case 8:out_arg=(float*)qmf_arena;break;case 9:*(unsigned*)(qmf_arena+508)=0x7fc12345;break;case 10:*(unsigned*)(low+319)=0x7f800000;break;case 11:for(unsigned i=0;i<320;i++){low[i]=FLT_MAX;high[i]=-FLT_MAX;}break;case 12:lo=(float*)(UINTPTR_MAX-20);break;}
  memcpy(qmf_saved,qmf_arena,512);CHECK(!spx_qmf_synth(state_arg,lo,hi,out_arg,n,cap));CHECK(!memcmp(qmf_saved,qmf_arena,512));untouched(output,sizeof(output));rejections++;
 }
}
int main(void){qmf();encoded();gain_sweeps();compatibility();guarded_frames();rejected();printf("{\"suite\":\"speex-wideband\",\"checks\":%llu,\"exact_float_words\":%llu,\"qmf_cases\":%llu,\"frames\":%llu,\"loss_frames\":%llu,\"dtx_frames\":%llu,\"recovery_frames\":%llu,\"gain_frames\":%llu,\"compatibility_frames\":%llu,\"packets\":%llu,\"nb_mode_mask\":%u,\"wb_mode_mask\":%u,\"uwb_mode_mask\":%u,\"rejections\":%llu}\n",(unsigned long long)checks,(unsigned long long)words,(unsigned long long)qmf_cases,(unsigned long long)frames,(unsigned long long)loss_frames,(unsigned long long)dtx_frames,(unsigned long long)recovery_frames,(unsigned long long)gain_frames,(unsigned long long)compatibility_frames,(unsigned long long)packets,mode_masks[0],mode_masks[1],mode_masks[2],(unsigned long long)rejections);return 0;}
