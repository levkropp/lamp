/* Unmodified official decoder versus connected original NB assembly. */
#include "lamp-test.h"
#include <math.h>
#include <float.h>
#include "speex/speex.h"
#include "speex/speex_stereo.h"
#include "nb_celp.h"
#include "modes.h"
typedef struct {const unsigned char *data;uint32_t bits,pos,error,reserved;} Bits;
LAMP_ABI int spx_nb_init(void*,unsigned);
LAMP_ABI int spx_nb_set_flags(void*,unsigned);
LAMP_ABI int spx_nb_frame(void*,Bits*,float*,unsigned);
static uint64_t checks,words,frames,dtx_frames,loss_frames,recovery_frames,rejections,packets,manual_frames,framing_frames;
static unsigned quality_context,frame_context,flag_context,mode_mask;
static uint32_t rng=0x979123ab;
static uint32_t next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"line %d quality=%u frame=%u flags=%u: %s\n",__LINE__,quality_context,frame_context,flag_context,#x);exit(1);}}while(0)
static unsigned u32(const unsigned char*a,unsigned off){unsigned v;memcpy(&v,a+off,4);return v;}
static void exact(const float*a,const void*b,unsigned n,const char*what){for(unsigned i=0;i<n;i++){uint32_t x,y;memcpy(&x,a+i,4);memcpy(&y,(const unsigned char*)b+4*i,4);if(x!=y){float f;memcpy(&f,&y,4);fprintf(stderr,"%s word %u reference=%a/%08x assembly=%a/%08x quality=%u frame=%u flags=%u\n",what,i,(double)a[i],x,(double)f,y,quality_context,frame_context,flag_context);exit(1);}CHECK(x==y);}words+=n;}
static Bits reader(SpeexBits*b){Bits r={(unsigned char*)b->chars,(unsigned)b->nbBits,(unsigned)(b->charPtr*8+b->bitPtr),0,0};return r;}
typedef struct {unsigned char*allocation,*data;size_t size,body,page;} Guard;
static Guard guarded(size_t n,int front){SYSTEM_INFO info;GetSystemInfo(&info);size_t page=info.dwPageSize,body=(n+page-1)/page*page;if(!body)body=page;Guard g={0};DWORD old;g.allocation=VirtualAlloc(NULL,body+page*2,MEM_RESERVE|MEM_COMMIT,PAGE_NOACCESS);CHECK(g.allocation&&VirtualProtect(g.allocation+page,body,PAGE_READWRITE,&old));g.data=g.allocation+page+(front?0:body-n);g.size=n;g.body=body;g.page=page;return g;}
static void release(Guard*g){CHECK(VirtualFree(g->allocation,0,MEM_RELEASE));}
static void untouched(const void*p,size_t n){const unsigned char*b=p;for(size_t i=0;i<n;i++)CHECK(b[i]==0xa5);}
static void state(DecState*s,const unsigned char*a,const float*innovation){
 CHECK(u32(a,4)==(unsigned)s->first&&u32(a,8)==(unsigned)s->count_lost&&u32(a,12)==(unsigned)s->submodeID&&u32(a,20)==s->seed);
 CHECK(u32(a,24)==(unsigned)s->last_pitch&&u32(a,28)==(unsigned)s->pitch_gain_buf_idx&&u32(a,32)==(unsigned)s->dtx_enabled&&u32(a,36)==(unsigned)s->voc_offset);
 exact(&s->last_ol_gain,a+44,1,"global gain");exact(&s->last_pitch_gain,a+48,1,"pitch gain");exact(&s->level,a+52,1,"level");exact(&s->max_level,a+56,1,"max level");exact(&s->min_level,a+60,1,"min level");
 exact(&s->voc_m1,a+64,1,"voc m1");exact(&s->voc_m2,a+68,1,"voc m2");exact(&s->voc_mean,a+72,1,"voc mean");
 exact(s->old_qlsp,a+80,10,"old LSP");exact(s->interp_qlpc,a+128,10,"LPC");exact(s->mem_sp,a+176,10,"synthesis memory");exact(s->mem_hp,a+224,2,"highpass memory");exact(s->pi_gain,a+240,4,"pi gain");exact(s->pitch_gain_buf,a+256,3,"gain ring");exact(s->excBuf,a+272,500,"excitation buffer");exact(innovation,a+2272,160,"innovation");
}
static DecState*decoder(unsigned char*a,float*innovation,unsigned flags){DecState*d=speex_decoder_init(&speex_nb_mode);CHECK(d&&spx_nb_init(a,8192)&&spx_nb_set_flags(a,flags));int on=!!(flags&1);CHECK(!speex_decoder_ctl(d,SPEEX_SET_ENH,&on));on=!!(flags&2);CHECK(!speex_decoder_ctl(d,SPEEX_SET_HIGHPASS,&on));on=!!(flags&4);CHECK(!speex_decoder_ctl(d,SPEEX_SET_WIDEBAND,&on));memset(innovation,0,640);CHECK(!speex_decoder_ctl(d,SPEEX_SET_INNOVATION_SAVE,innovation));return d;}
static void decode(DecState*d,unsigned char*a,float*innovation,SpeexBits*ref,Bits*b){float expected[160],actual[160];int dtx=d->dtx_enabled,lost=d->count_lost;memset(actual,0xa5,sizeof(actual));CHECK(!speex_decode(d,ref,expected));CHECK(spx_nb_frame(a,b,actual,160)==160);if(b)CHECK(!b->error&&b->pos==(unsigned)(ref->charPtr*8+ref->bitPtr));state(d,a,innovation);exact(expected,actual,160,"PCM");mode_mask|=1u<<d->submodeID;frames++;if(!ref){if(dtx)dtx_frames++;else loss_frames++;}else if(lost)recovery_frames++;}
static void encoded(void){
 const unsigned groups[]={1,2,5,64};
 for(unsigned flags=0;flags<8;flags++)for(unsigned quality=0;quality<=10;quality++)for(unsigned variation=0;variation<3;variation++){
  quality_context=quality;flag_context=flags;unsigned char arena[8192];float innovation[160];DecState*d=decoder(arena,innovation,flags);void*enc=speex_encoder_init(&speex_nb_mode);CHECK(enc);int q=quality;CHECK(!speex_encoder_ctl(enc,SPEEX_SET_QUALITY,&q));int on=variation!=0;CHECK(!speex_encoder_ctl(enc,SPEEX_SET_VBR,&on));on=variation==2;CHECK(!speex_encoder_ctl(enc,SPEEX_SET_VAD,&on));CHECK(!speex_encoder_ctl(enc,SPEEX_SET_DTX,&on));
  unsigned group=groups[(quality+variation)%4],count=group==64?256:160;
  for(unsigned base=0;base<count;base+=group){SpeexBits packed;speex_bits_init(&packed);for(unsigned j=0;j<group;j++){float input[320];unsigned frame=base+j;for(unsigned i=0;i<160;i++){double t=(frame*160+i)/8000.;float x=frame%80<24?0.f:frame%80<48?(float)(10000*sin(6.283185307179586*223*t)+2000*sin(6.283185307179586*611*t)):((int)(next()%24001)-12000)*.4f;input[i*2]=x;input[i*2+1]=.7f*x;}
    if(variation==1){speex_encode_stereo(input,160,&packed);}else for(unsigned i=0;i<160;i++)input[i]=input[i*2];
    CHECK(speex_encode(enc,input,&packed)>=0);
   }speex_bits_rewind(&packed);Bits bits=reader(&packed);for(unsigned j=0;j<group;j++){frame_context=base+j;if((base+j)%37==0&&!d->dtx_enabled){for(unsigned k=0;k<1+(base+j)%16;k++)decode(d,arena,innovation,NULL,NULL);}decode(d,arena,innovation,&packed,&bits);if(d->dtx_enabled&&variation==2&&j+1==group){for(unsigned k=0;k<3;k++)decode(d,arena,innovation,NULL,NULL);}}
   CHECK(bits.pos==(unsigned)packed.nbBits);packets++;speex_bits_destroy(&packed);
  }speex_encoder_destroy(enc);speex_decoder_destroy(d);
 }
}
static void manual(void){
 /* Sweep every global-gain and voiced-gain code, including null/DTX mode. */
 for(unsigned flags=0;flags<8;flags++)for(unsigned gain=0;gain<32;gain++)for(unsigned coef=0;coef<16;coef++){
  unsigned char arena[8192];float innovation[160];flag_context=flags;quality_context=99;frame_context=gain*16+coef;DecState*d=decoder(arena,innovation,flags);SpeexBits packed;speex_bits_init(&packed);speex_bits_pack(&packed,0,1);speex_bits_pack(&packed,1,4);speex_bits_pack(&packed,0,18);speex_bits_pack(&packed,(gain*7+coef)%128,7);speex_bits_pack(&packed,coef,4);speex_bits_pack(&packed,gain,5);speex_bits_pack(&packed,15,4);speex_bits_rewind(&packed);Bits bits=reader(&packed);decode(d,arena,innovation,&packed,&bits);manual_frames++;decode(d,arena,innovation,NULL,NULL);decode(d,arena,innovation,NULL,NULL);speex_bits_destroy(&packed);speex_decoder_destroy(d);
 }
}
static void framing(void){
 const unsigned sizes[]={1,1,4,4,4,4,4,4,8,8,16,16,32,32,64,64},wb[]={0,36,112,192,352};
 void*enc=speex_encoder_init(&speex_nb_mode);int mode=5;CHECK(!speex_encoder_ctl(enc,SPEEX_SET_MODE,&mode));SpeexBits base;speex_bits_init(&base);float input[160];for(unsigned i=0;i<160;i++)input[i]=(float)(8000*sin(.09*i));CHECK(speex_encode(enc,input,&base)>=0);
 for(unsigned flags=0;flags<8;flags++)for(unsigned kind=0;kind<3;kind++)for(unsigned code=0;code<(kind==2?4u:16u);code++){
  flag_context=flags;quality_context=98;frame_context=kind*16+code;unsigned char arena[8192];float innovation[160];DecState*d=decoder(arena,innovation,flags);SpeexBits packet;speex_bits_init(&packet);
  if(kind<2){speex_bits_pack(&packet,0,1);speex_bits_pack(&packet,kind==0?14:13,4);speex_bits_pack(&packet,code,4);unsigned n=kind==0?sizes[code]:5+8*code;for(unsigned j=0;j<n;j++)speex_bits_pack(&packet,(j+code)&1,1);}
  else for(unsigned layer=0;layer<1+(code&1);layer++){speex_bits_pack(&packet,1,1);speex_bits_pack(&packet,code+1,3);for(unsigned j=4;j<wb[code+1];j++)speex_bits_pack(&packet,0,1);}
  for(unsigned j=0;j<(unsigned)base.nbBits;j++)speex_bits_pack(&packet,((unsigned char*)base.chars)[j/8]>>(7-j%8)&1,1);
  speex_bits_rewind(&packet);Bits b=reader(&packet);decode(d,arena,innovation,&packet,&b);CHECK(b.pos==(unsigned)packet.nbBits);if(kind==0&&code==9)CHECK(u32(arena,40)==0xaa);framing_frames++;speex_bits_destroy(&packet);speex_decoder_destroy(d);
 }
 speex_bits_destroy(&base);speex_encoder_destroy(enc);
 /* Higher-band null layers are four bits, despite the reference NB skip
    table's negative advance for that specific compatibility-only case. */
 for(unsigned layers=1;layers<=2;layers++){unsigned char arena[8192];float innovation[160],output[160];DecState*d=decoder(arena,innovation,3);SpeexBits packet;speex_bits_init(&packet);for(unsigned j=0;j<layers;j++){speex_bits_pack(&packet,1,1);speex_bits_pack(&packet,0,3);}speex_bits_pack(&packet,0,5);speex_bits_rewind(&packet);Bits b=reader(&packet);CHECK(spx_nb_frame(arena,&b,output,160)==160&&b.pos==layers*4+5&&!b.error);speex_bits_destroy(&packet);speex_decoder_destroy(d);}
}
static void rejected(void){
 /* Every truncated bit prefix of all eight coded modes is kept against
    inaccessible pages, with reader/output and live history canaries. */
 for(unsigned mode=1;mode<=8;mode++){
  void*enc=speex_encoder_init(&speex_nb_mode);int value=mode;CHECK(!speex_encoder_ctl(enc,SPEEX_SET_MODE,&value));SpeexBits packet;speex_bits_init(&packet);float input[160];for(unsigned j=0;j<160;j++)input[j]=(float)(5000*sin(.07*j));CHECK(speex_encode(enc,input,&packet)>=0);speex_bits_rewind(&packet);unsigned nbits=packet.nbBits;
  for(unsigned front=0;front<2;front++)for(unsigned available=0;available<nbits;available++){
   unsigned bytes=(available+7)/8;Guard src=guarded(bytes,front),arena=guarded(8192+32,0),output=guarded(640+32,0),reader_mem=guarded(sizeof(Bits)+32,0);memcpy(src.data,packet.chars,bytes);DWORD old;CHECK(VirtualProtect(src.allocation+src.page,src.body,PAGE_READONLY,&old));memset(arena.data,0xa5,arena.size);CHECK(spx_nb_init(arena.data+32,8192));unsigned char saved[2912];memcpy(saved,arena.data+32,sizeof(saved));memset(output.data,0xa5,output.size);memset(reader_mem.data,0xa5,reader_mem.size);Bits*b=(Bits*)(reader_mem.data+32);*b=(Bits){bytes?src.data:NULL,available,0,0,0};int result=spx_nb_frame(arena.data+32,b,(float*)(output.data+32),160);CHECK(result==(available<5?0:-1)&&b->pos==0&&b->error==(available>=5));CHECK(!memcmp(saved,arena.data+32,sizeof(saved)));untouched(arena.data,32);untouched(reader_mem.data,32);untouched(output.data,output.size);release(&src);release(&arena);release(&output);release(&reader_mem);rejections++;
  }
  /* A complete protected input succeeds with the same guard arrangement. */
  Guard src=guarded((nbits+7)/8,0),arena=guarded(8192+32,0),output=guarded(640+32,0);memcpy(src.data,packet.chars,src.size);DWORD old;CHECK(VirtualProtect(src.allocation+src.page,src.body,PAGE_READONLY,&old));memset(arena.data,0xa5,arena.size);memset(output.data,0xa5,output.size);CHECK(spx_nb_init(arena.data+32,8192));Bits bits={src.data,nbits,0,0,0};CHECK(spx_nb_frame(arena.data+32,&bits,(float*)(output.data+32),160)==160&&bits.pos==nbits&&!bits.error);untouched(arena.data,32);untouched(output.data,32);release(&src);release(&arena);release(&output);speex_bits_destroy(&packet);speex_encoder_destroy(enc);
 }
 unsigned char arena[8192],saved[2912],data[1024]={0};float output[160];Bits b;
 for(unsigned mutation=0;mutation<29;mutation++){
  CHECK(spx_nb_init(arena,8192));memset(output,0xa5,sizeof(output));b=(Bits){data,sizeof(data)*8,0,0,0};data[0]=0x28; /* mode 5, sufficient payload */
  void*state_arg=arena;Bits*bits_arg=&b;float*out_arg=output;unsigned capacity=160;
  switch(mutation){case 0:state_arg=NULL;break;case 1:out_arg=NULL;break;case 2:capacity=159;break;case 3:bits_arg=(Bits*)arena;break;case 4:out_arg=(float*)arena;break;case 5:out_arg=(float*)&b;break;case 6:out_arg=(float*)data;break;case 7:b.data=arena;break;case 8:b.data=(unsigned char*)&b;break;case 9:b.data=NULL;break;case 10:b.bits=8388609;break;case 11:b.pos=b.bits+1;break;case 12:b.error=1;break;case 13:arena[0]=0;break;case 14:*(unsigned*)(arena+16)=8;break;case 15:*(unsigned*)(arena+28)=3;break;case 16:*(int*)(arena+36)=-161;break;case 17:*(unsigned*)(arena+8)=1000000001;break;case 18:*(unsigned*)(arena+24)=145;break;case 19:*(unsigned*)(arena+4)=2;break;case 20:*(unsigned*)(arena+32)=2;break;case 21:*(unsigned*)(arena+12)=9;break;case 22:*(unsigned*)(arena+80)=0x7fc12345;break;case 23:*(float*)(arena+80)=17.f;break;case 24:*(unsigned*)(arena+2912-4)=0x7f800000;break;case 25:out_arg=(float*)(UINTPTR_MAX-20);break;case 26:b.data=(unsigned char*)(UINTPTR_MAX-20);break;case 27:*(float*)(arena+128)=FLT_MAX;*(float*)(arena+176)=FLT_MAX;bits_arg=NULL;break;case 28:*(float*)(arena+128)=FLT_MAX;*(float*)(arena+176+36)=FLT_MAX;break;}
  memcpy(saved,arena,sizeof(saved));Bits before=b;CHECK(spx_nb_frame(state_arg,bits_arg,out_arg,capacity)==-1);CHECK(!memcmp(arena,saved,sizeof(saved)));CHECK(!memcmp(&b,&before,sizeof(b)));untouched(output,sizeof(output));rejections++;
 }
 CHECK(!spx_nb_init(NULL,8192));memset(arena,0xa5,sizeof(arena));CHECK(!spx_nb_init(arena,8191));untouched(arena,sizeof(arena));CHECK(!spx_nb_set_flags(NULL,0));CHECK(!spx_nb_set_flags(arena,0));CHECK(spx_nb_init(arena,8192));CHECK(!spx_nb_set_flags(arena,8));rejections+=5;
 /* Invalid modes, truncated controls, third upper band, and >1024 requests
    fail atomically. A clean terminator may consume bits without a frame. */
 for(unsigned mutation=0;mutation<9;mutation++){
  CHECK(spx_nb_init(arena,8192));SpeexBits packet;speex_bits_init(&packet);
  if(mutation<4){speex_bits_pack(&packet,0,1);speex_bits_pack(&packet,9+mutation,4);}
  else if(mutation==4){speex_bits_pack(&packet,0,1);speex_bits_pack(&packet,14,4);}
  else if(mutation==5){speex_bits_pack(&packet,0,1);speex_bits_pack(&packet,13,4);speex_bits_pack(&packet,15,4);}
  else if(mutation==6){for(unsigned j=0;j<3;j++){speex_bits_pack(&packet,1,1);speex_bits_pack(&packet,0,3);}speex_bits_pack(&packet,0,5);}
  else if(mutation==7){speex_bits_pack(&packet,1,1);speex_bits_pack(&packet,5,3);speex_bits_pack(&packet,0,1);}
  else for(unsigned j=0;j<1025;j++){speex_bits_pack(&packet,0,1);speex_bits_pack(&packet,14,4);speex_bits_pack(&packet,0,4);speex_bits_pack(&packet,0,1);}
  speex_bits_rewind(&packet);b=reader(&packet);memcpy(saved,arena,sizeof(saved));memset(output,0xa5,sizeof(output));CHECK(spx_nb_frame(arena,&b,output,160)==-1&&!b.pos);CHECK(!memcmp(saved,arena,sizeof(saved)));untouched(output,sizeof(output));rejections++;speex_bits_destroy(&packet);
 }
 CHECK(spx_nb_init(arena,8192));data[0]=0x78;b=(Bits){data,5,0,0,0};memset(output,0xa5,sizeof(output));CHECK(spx_nb_frame(arena,&b,output,160)==0&&b.pos==5&&!b.error);untouched(output,sizeof(output));
}
int main(void){manual();encoded();framing();rejected();printf("{\"suite\":\"speex-nb\",\"checks\":%llu,\"exact_float_words\":%llu,\"frames\":%llu,\"dtx_null_frames\":%llu,\"loss_frames\":%llu,\"recovery_frames\":%llu,\"manual_gain_frames\":%llu,\"framing_frames\":%llu,\"packets\":%llu,\"mode_mask\":%u,\"rejections\":%llu}\n",(unsigned long long)checks,(unsigned long long)words,(unsigned long long)frames,(unsigned long long)dtx_frames,(unsigned long long)loss_frames,(unsigned long long)recovery_frames,(unsigned long long)manual_frames,(unsigned long long)framing_frames,(unsigned long long)packets,mode_mask,(unsigned long long)rejections);return 0;}
