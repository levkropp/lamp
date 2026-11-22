/* Test-only official Speex reference versus bounded assembly excitation. */
#include "lamp-test.h"
#include <math.h>
#include <float.h>
#include "speex/speex.h"
#include "speex/speex_stereo.h"
#include "ltp.h"
#include "cb_search.h"
#include "math_approx.h"
#include "speex-excitation-test.h"
typedef struct {const unsigned char*data;uint32_t bits,pos,error,reserved;} Bits;
typedef struct {float*exc,*output;uint32_t history,samples,start,end,kind,lost,offset;float last_gain,coefficient;uint32_t capacity,pitch;float gains[3],gain_sum;uint32_t reserved;} Pitch;
LAMP_ABI int spx_bits_init(Bits*,const void*,unsigned);
LAMP_ABI int spx_pitch_decode(Bits*,Pitch*);
LAMP_ABI int spx_innovation_decode(Bits*,float*,unsigned,unsigned);
LAMP_ABI int spx_noise_decode(float*,unsigned,uint32_t*,float);
extern const signed char gain_cdbk_nb[],gain_cdbk_lbr[];
extern const signed char exc_10_16_table[],exc_20_32_table[],exc_10_32_table[],exc_5_64_table[],exc_8_128_table[],exc_5_256_table[],hexc_10_32_table[],hexc_table[];
static const ltp_params pitches[]={{gain_cdbk_nb,7,7},{gain_cdbk_lbr,5,7},{gain_cdbk_lbr,5,0}};
static const split_cb_params shapes[]={{10,4,exc_10_16_table,4,0},{20,2,exc_20_32_table,5,0},{10,4,exc_10_32_table,5,0},{5,8,exc_5_64_table,6,0},{8,5,exc_8_128_table,7,0},{5,8,exc_5_256_table,8,0},{10,4,hexc_10_32_table,5,0},{8,5,hexc_table,7,1}};
static uint64_t checks,words,pitch_cases,forced_cases,innovation_cases,noise_samples,rejections,codec_frames,losses,live_pitch,live_forced,live_innovation,live_noise;
static unsigned pitch_mask,shape_mask,mode_context,quality_context,frame_context;
static uint32_t rng=0x779217ab;
static char scratch[8192];
static unsigned char noise_seen[1u<<20]; /* verify the full 23-bit cycle */
static uint32_t next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"line %d mode=%u quality=%u frame=%u: %s\n",__LINE__,mode_context,quality_context,frame_context,#x);exit(1);}}while(0)
typedef struct {unsigned char*allocation,*data;size_t size;} Guard;
static Guard guarded(size_t n,int front){SYSTEM_INFO info;GetSystemInfo(&info);size_t page=info.dwPageSize,body=(n+page-1)/page*page;if(!body)body=page;Guard g={0};DWORD old;g.allocation=VirtualAlloc(NULL,body+page*2,MEM_RESERVE|MEM_COMMIT,PAGE_NOACCESS);CHECK(g.allocation&&VirtualProtect(g.allocation+page,body,PAGE_READWRITE,&old));g.data=g.allocation+page+(front?0:body-n);g.size=n;return g;}
static void release(Guard*g){CHECK(VirtualFree(g->allocation,0,MEM_RELEASE));}
static void exact(const float*a,const float*b,unsigned n,const char*what){for(unsigned i=0;i<n;i++){uint32_t x,y;memcpy(&x,a+i,4);memcpy(&y,b+i,4);if(x!=y){fprintf(stderr,"%s word %u reference=%a/%08x assembly=%a/%08x mode=%u quality=%u frame=%u\n",what,i,(double)a[i],x,(double)b[i],y,mode_context,quality_context,frame_context);exit(1);}CHECK(x==y);}words+=n;}
static Bits reader(SpeexBits*b){Bits result={(unsigned char*)b->chars,(unsigned)b->nbBits,(unsigned)(b->charPtr*8+b->bitPtr),0,0};return result;}
static void output_canary(const Guard*g){for(unsigned j=0;j<32;j++)CHECK(g->data[j]==0xa5);}
static void untouched(const Guard*g){for(size_t j=0;j<g->size;j++)CHECK(g->data[j]==0xa5);}
static unsigned pitch_kind(int forced,const ltp_params*p){if(forced)return 3;for(unsigned i=0;i<3;i++)if(p->gain_cdbk==pitches[i].gain_cdbk&&p->gain_bits==pitches[i].gain_bits&&p->pitch_bits==pitches[i].pitch_bits)return i;CHECK(0);return 0;}
static unsigned shape_kind(const split_cb_params*p){for(unsigned i=0;i<8;i++)if(p->shape_cb==shapes[i].shape_cb&&p->subvect_size==shapes[i].subvect_size&&p->nb_subvect==shapes[i].nb_subvect&&p->shape_bits==shapes[i].shape_bits&&p->have_sign==shapes[i].have_sign)return i;CHECK(0);return 0;}
void test_speex_pitch(int forced,SpxPitchRef ref,float*exc,float*out,int start,int end,float coef,const void*params,int n,int*pitch,float*gains,SpeexBits*bits,char*stack,int lost,int offset,float last_gain,int book_offset){
 CHECK(n>0&&n<=80&&book_offset==0);float copied[145+80],actual[80];memcpy(copied,exc-145,(145+n)*4);Bits input=reader(bits);unsigned kind=pitch_kind(forced,(const ltp_params*)params);Pitch job={copied+145,actual,145,(unsigned)n,(unsigned)start,(unsigned)end,kind,(unsigned)lost,(unsigned)offset,last_gain,coef,80,0,{0,0,0},0,0};
 ref(exc,out,start,end,coef,params,n,pitch,gains,bits,stack,lost,offset,last_gain,book_offset);CHECK(spx_pitch_decode(&input,&job));CHECK(input.pos==(unsigned)(bits->charPtr*8+bits->bitPtr)&&!input.error&&job.pitch==(unsigned)*pitch&&job.reserved==0);exact(out,actual,n,"live pitch output");exact(gains,job.gains,3,"live pitch gains");float sum=gain_3tap_to_1tap(gains);exact(&sum,&job.gain_sum,1,"live gain sum");exact(exc,copied+145,n,"live excitation history");pitch_mask|=1u<<kind;if(forced)live_forced++;else live_pitch++;
}
void test_speex_innovation(int noise,SpxInnovationRef ref,float*exc,const void*params,int n,SpeexBits*bits,char*stack,uint32_t*seed){
 CHECK(n>0&&n<=640);float actual[640];memcpy(actual,exc,n*4);uint32_t expected_seed=*seed;Bits input=reader(bits);unsigned kind=noise?0:shape_kind((const split_cb_params*)params);ref(exc,params,n,bits,stack,seed);
 if(noise){CHECK(spx_noise_decode(actual,n,&expected_seed,1.f));CHECK(expected_seed==*seed);live_noise++;}
 else {CHECK(n==40);CHECK(spx_innovation_decode(&input,actual,kind,n)==40);CHECK(input.pos==(unsigned)(bits->charPtr*8+bits->bitPtr)&&!input.error&&expected_seed==*seed);shape_mask|=1u<<kind;live_innovation++;}
 exact(exc,actual,n,"live innovation/noise");
}
static void pitch_vectors(void){
 const unsigned sizes[]={1,2,17,39,40,41,80};
 for(unsigned kind=0;kind<3;kind++){
  unsigned pitch_count=1u<<pitches[kind].pitch_bits,gain_count=1u<<pitches[kind].gain_bits;
  for(unsigned pi=0;pi<pitch_count;pi++)for(unsigned gain=0;gain<gain_count;gain++)for(unsigned loss_case=0;loss_case<3;loss_case++){
   unsigned pitch=17+pi,n=sizes[(pi+gain+loss_case)%7],history=pitch+1;Guard source=guarded(history*4,((pi+gain)&1)!=0),output=guarded(n*4+32,0),request=guarded(sizeof(Pitch)+32,0);float ref_storage[145+80],expected[80],expected_gains[3];for(unsigned j=0;j<history;j++)ref_storage[j]=((int)(next()%64001)-32000)/64.f;memcpy(source.data,ref_storage,history*4);memset(ref_storage+history,0,n*4);
   SpeexBits packed;speex_bits_init(&packed);unsigned prefix=(pi+gain)%8;speex_bits_pack(&packed,0,prefix);speex_bits_pack(&packed,pi,pitches[kind].pitch_bits);speex_bits_pack(&packed,gain,pitches[kind].gain_bits);SpeexBits ref=packed;ref.owner=0;ref.charPtr=prefix/8;ref.bitPtr=prefix%8;Bits input=reader(&ref);unsigned lost=loss_case==0?0:loss_case==1?1:8,offset=(pi+gain)%3*40;float last=(pi+gain)%7*.2f;
   memset(output.data,0xa5,output.size);memset(request.data,0xa5,request.size);Pitch*job=(Pitch*)(request.data+32);*job=(Pitch){(float*)(source.data+history*4),(float*)(output.data+32),history,n,17,144,kind,lost,offset,last,0.f,n,0,{0,0,0},0,0};int ref_pitch;
   spxref_pitch_unquant_3tap(ref_storage+history,expected,17,144,0.f,pitches+kind,n,&ref_pitch,expected_gains,&ref,scratch,lost,offset,last,0);CHECK(spx_pitch_decode(&input,job));CHECK(job->pitch==(unsigned)ref_pitch&&input.pos==(unsigned)(ref.charPtr*8+ref.bitPtr)&&!input.error);exact(expected,job->output,n,"pitch");exact(expected_gains,job->gains,3,"pitch gains");float sum=gain_3tap_to_1tap(expected_gains);exact(&sum,&job->gain_sum,1,"pitch sum");CHECK(!memcmp(ref_storage,source.data,history*4));output_canary(&output);output_canary(&request);pitch_cases++;
   speex_bits_destroy(&packed);release(&source);release(&output);release(&request);
  }
 }
 const float coefs[]={0.f,-0.f,.125f,.5f,.99f,1.f,4.f};
 for(unsigned pitch=1;pitch<=144;pitch++)for(unsigned ci=0;ci<7;ci++)for(unsigned size=0;size<7;size++){
  unsigned n=sizes[size];Guard source=guarded((pitch+n)*4,ci&1),output=guarded(n*4+32,0);float storage[144+80],expected[80],gains[3];for(unsigned j=0;j<pitch+n;j++)storage[j]=((int)(next()%65537)-32768)/128.f;memcpy(source.data,storage,(pitch+n)*4);memset(output.data,0xa5,output.size);Bits bits;CHECK(spx_bits_init(&bits,NULL,0));Pitch job={(float*)source.data+pitch,(float*)(output.data+32),pitch,n,pitch,pitch,3,0,0,0.f,coefs[ci],n,0,{0,0,0},0,0};int reference_pitch;
  spxref_forced_pitch_unquant(storage+pitch,expected,pitch,pitch,coefs[ci],NULL,n,&reference_pitch,gains,NULL,scratch,0,0,0.f,0);CHECK(spx_pitch_decode(&bits,&job));CHECK(job.pitch==pitch&&!bits.pos&&!bits.error);exact(expected,job.output,n,"forced pitch");exact(gains,job.gains,3,"forced gains");exact(storage+pitch,job.exc,n,"forced updated history");float sum=gain_3tap_to_1tap(gains);exact(&sum,&job.gain_sum,1,"forced gain sum");CHECK(!memcmp(storage,source.data,pitch*4));output_canary(&output);forced_cases++;release(&source);release(&output);
 }
}
static void innovation_vectors(void){
 for(unsigned kind=0;kind<8;kind++)for(unsigned chosen=0;chosen<(1u<<shapes[kind].shape_bits);chosen++)for(unsigned sign=0;sign<=(unsigned)shapes[kind].have_sign;sign++)for(unsigned additive=0;additive<3;additive++){
  Guard output=guarded(160+32,0);float expected[40];for(unsigned j=0;j<40;j++)expected[j]=additive==0?0.f:additive==1?-0.f:((int)(next()%65537)-32768)/131072.f;memset(output.data,0xa5,output.size);memcpy(output.data+32,expected,160);SpeexBits packed;speex_bits_init(&packed);unsigned prefix=chosen%8;speex_bits_pack(&packed,0,prefix);
  for(int j=0;j<shapes[kind].nb_subvect;j++){if(shapes[kind].have_sign)speex_bits_pack(&packed,sign,1);speex_bits_pack(&packed,(chosen+j)%(1u<<shapes[kind].shape_bits),shapes[kind].shape_bits);}SpeexBits reference=packed;reference.owner=0;reference.charPtr=prefix/8;reference.bitPtr=prefix%8;Bits input=reader(&reference);uint32_t seed=1000;
  spxref_split_cb_shape_sign_unquant(expected,shapes+kind,40,&reference,scratch,&seed);CHECK(spx_innovation_decode(&input,(float*)(output.data+32),kind,40)==40);CHECK(input.pos==(unsigned)(reference.charPtr*8+reference.bitPtr)&&!input.error&&seed==1000);exact(expected,(float*)(output.data+32),40,"innovation");output_canary(&output);innovation_cases++;speex_bits_destroy(&packed);release(&output);
 }
}
static void noise_vectors(void){
 uint32_t ours=0,reference=0;Guard output=guarded(640*4+32,0);float expected[640];unsigned remaining=1u<<23;
 while(remaining){unsigned n=remaining>640?640:remaining;for(unsigned j=0;j<n;j++){expected[j]=speex_rand(1.f,&reference);unsigned mantissa=reference&0x7fffff,mask=1u<<(mantissa&7);CHECK(!(noise_seen[mantissa>>3]&mask));noise_seen[mantissa>>3]|=mask;}memset(output.data,0xa5,output.size);CHECK(spx_noise_decode((float*)(output.data+32),n,&ours,1.f));CHECK(ours==reference);exact(expected,(float*)(output.data+32),n,"noise mantissa cycle");output_canary(&output);for(size_t j=32+n*4;j<output.size;j++)CHECK(output.data[j]==0xa5);remaining-=n;noise_samples+=n;}
 CHECK((ours&0x7fffff)==0);const float deviations[]={0.f,-0.f,1e-38f,.1f,1.f,1000.f};
 for(unsigned trial=0;trial<4096;trial++){ours=reference=next();float dev=deviations[trial%6];unsigned n=1+next()%640;for(unsigned j=0;j<n;j++)expected[j]=speex_rand(dev,&reference);memset(output.data,0xa5,output.size);CHECK(spx_noise_decode((float*)(output.data+32),n,&ours,dev));CHECK(ours==reference);exact(expected,(float*)(output.data+32),n,"noise arbitrary scale");for(size_t j=32+n*4;j<output.size;j++)CHECK(output.data[j]==0xa5);noise_samples+=n;}
 CHECK(spx_noise_decode(NULL,0,NULL,0.f));release(&output);
}
static void rejected(void){
 float memory[145+80]={0};Guard output=guarded(80*4+32,0);unsigned char data[16]={0};Bits bits;Pitch original={memory+145,(float*)(output.data+32),145,40,17,144,0,0,0,0.f,0.f,80,0xdddddddd,{0.f,0.f,0.f},0.f,0xdddddddd};
 for(unsigned kind=0;kind<3;kind++){unsigned required=pitches[kind].gain_bits+pitches[kind].pitch_bits;for(unsigned available=0;available<required;available++){CHECK(spx_bits_init(&bits,data,sizeof(data)));bits.bits=available;Pitch job=original;job.kind=kind;Pitch saved=job;memset(output.data,0xa5,output.size);CHECK(!spx_pitch_decode(&bits,&job)&&bits.error&&!bits.pos);CHECK(!memcmp(&saved,&job,sizeof(job)));untouched(&output);rejections++;}}
 for(unsigned kind=0;kind<8;kind++){unsigned required=shapes[kind].nb_subvect*(shapes[kind].shape_bits+shapes[kind].have_sign);for(unsigned available=0;available<required;available++){CHECK(spx_bits_init(&bits,data,sizeof(data)));bits.bits=available;memset(output.data,0xa5,output.size);CHECK(!spx_innovation_decode(&bits,(float*)(output.data+32),kind,80)&&bits.error&&!bits.pos);untouched(&output);rejections++;}}
 for(unsigned mutation=0;mutation<16;mutation++){CHECK(spx_bits_init(&bits,data,sizeof(data)));Pitch job=original;switch(mutation){case 0:job.kind=4;break;case 1:job.samples=0;break;case 2:job.samples=81;break;case 3:job.capacity=39;break;case 4:job.start=0;break;case 5:job.end=145;break;case 6:job.history=17;break;case 7:job.history=513;break;case 8:job.output=job.exc;break;case 9:job.output=(float*)data;break;case 10:job.exc=NULL;break;case 11:job.output=NULL;break;case 12:job.output=(float*)(UINTPTR_MAX-7);break;case 13:job.exc=(float*)1;break;case 14:job.output=(float*)&bits;break;case 15:job.history=0;break;}Pitch saved=job;memset(output.data,0xa5,output.size);CHECK(!spx_pitch_decode(&bits,&job)&&!bits.pos);CHECK(!memcmp(&saved,&job,sizeof(job)));untouched(&output);rejections++;}
 uint32_t bads[]={0x7f800000,0xff800000,0x7fc12345,0x7f800001};for(unsigned k=0;k<4;k++){CHECK(spx_bits_init(&bits,data,sizeof(data)));Pitch job=original;memcpy(memory+144,bads+k,4);Pitch saved=job;memset(output.data,0xa5,output.size);CHECK(!spx_pitch_decode(&bits,&job)&&!bits.pos);CHECK(!memcmp(&saved,&job,sizeof(job)));untouched(&output);memory[144]=0;rejections++;}
 uint32_t seed=0,saved_seed;for(unsigned k=0;k<4;k++){float deviation;memcpy(&deviation,bads+k,4);memset(output.data,0xa5,output.size);saved_seed=seed;CHECK(!spx_noise_decode((float*)(output.data+32),80,&seed,deviation)&&seed==saved_seed);untouched(&output);rejections++;}memset(output.data,0xa5,output.size);CHECK(!spx_noise_decode((float*)(output.data+32),80,&seed,FLT_MAX)&&seed==0);untouched(&output);CHECK(!spx_noise_decode((float*)(output.data+32),641,&seed,1.f));CHECK(!spx_noise_decode((float*)(output.data+32),80,(uint32_t*)(output.data+32),1.f));CHECK(!spx_noise_decode(NULL,80,&seed,1.f));CHECK(!spx_noise_decode((float*)(UINTPTR_MAX-7),80,&seed,1.f));rejections+=5;
 CHECK(spx_bits_init(&bits,data,sizeof(data)));CHECK(!spx_innovation_decode(&bits,(float*)(output.data+32),8,80));CHECK(!spx_innovation_decode(&bits,(float*)(output.data+32),0,39));CHECK(!spx_pitch_decode(NULL,&original));CHECK(!spx_pitch_decode(&bits,NULL));rejections+=4;
 /* Job and mutable output aliases reject before reading outside an aliased
    object's contract. Numeric metadata fails without consuming source bits. */
 for(unsigned mutation=0;mutation<8;mutation++){CHECK(spx_bits_init(&bits,data,sizeof(data)));Pitch job=original;switch(mutation){case 0:job.exc=(float*)&bits;break;case 1:job.output=(float*)&job;break;case 2:bits.data=(unsigned char*)&job;break;case 3:bits.pos=bits.bits+1;break;case 4:job.kind=3;memcpy(&job.coefficient,bads,4);break;case 5:job.kind=3;job.coefficient=-1.f;break;case 6:job.lost=1;memcpy(&job.last_gain,bads,4);break;case 7:job.lost=1;job.last_gain=-1.f;break;}Pitch saved=job;unsigned before=bits.pos;memset(output.data,0xa5,output.size);CHECK(!spx_pitch_decode(&bits,&job)&&bits.pos==before);CHECK(!memcmp(&saved,&job,sizeof(job)));untouched(&output);rejections++;}
 for(unsigned k=0;k<4;k++){CHECK(spx_bits_init(&bits,data,sizeof(data)));memset(output.data,0xa5,output.size);memcpy(output.data+32+39*4,bads+k,4);unsigned char saved[80*4+32];memcpy(saved,output.data,output.size);CHECK(!spx_innovation_decode(&bits,(float*)(output.data+32),0,80)&&!bits.pos&&!bits.error);CHECK(!memcmp(saved,output.data,output.size));rejections++;}
 CHECK(spx_bits_init(&bits,output.data+32,16));memset(output.data,0xa5,output.size);CHECK(!spx_innovation_decode(&bits,(float*)(output.data+32),0,80)&&!bits.pos);untouched(&output);rejections++;
 /* A late pitch multiply overflow leaves all already computed samples in
    scratch, preserving bit position, request results and excitation. */
 unsigned gain=0;while(gain<128&&gain_cdbk_nb[gain*4+2]<=32)gain++;CHECK(gain<128);SpeexBits packed;speex_bits_init(&packed);speex_bits_pack(&packed,127,7);speex_bits_pack(&packed,gain,7);speex_bits_rewind(&packed);bits=reader(&packed);memset(memory,0,sizeof(memory));memory[70]=FLT_MAX;Pitch job=original;job.samples=80;Pitch saved=job;memset(output.data,0xa5,output.size);CHECK(!spx_pitch_decode(&bits,&job)&&!bits.pos&&!bits.error);CHECK(!memcmp(&saved,&job,sizeof(job)));untouched(&output);speex_bits_destroy(&packed);memory[70]=0;rejections++;
 /* The first draw is finite at this scale; a later draw overflows. */
 float deviation=.75f*FLT_MAX;uint32_t preview=0;unsigned first_bad=0;while(first_bad<80&&isfinite(speex_rand(deviation,&preview)))first_bad++;CHECK(first_bad>0&&first_bad<80);seed=0;memset(output.data,0xa5,output.size);CHECK(!spx_noise_decode((float*)(output.data+32),80,&seed,deviation)&&seed==0);untouched(&output);rejections++;
 release(&output);
}
static void codec_calls(void){
 for(unsigned mode=0;mode<3;mode++)for(unsigned quality=0;quality<=10;quality++)for(unsigned stereo=0;stereo<2;stereo++)for(unsigned policy=0;policy<3;policy++){
  mode_context=mode;quality_context=quality;const SpeexMode*m=speex_lib_get_mode(mode);void*encoder=speex_encoder_init(m),*decoder=speex_decoder_init(m);CHECK(encoder&&decoder);int q=quality,complexity=1,enabled=1;CHECK(!speex_encoder_ctl(encoder,SPEEX_SET_QUALITY,&q));CHECK(!speex_encoder_ctl(encoder,SPEEX_SET_COMPLEXITY,&complexity));if(policy==1)CHECK(!speex_encoder_ctl(encoder,SPEEX_SET_VBR,&enabled));if(policy==2){CHECK(!speex_encoder_ctl(encoder,SPEEX_SET_VAD,&enabled));CHECK(!speex_encoder_ctl(encoder,SPEEX_SET_DTX,&enabled));}
  SpeexBits bits;speex_bits_init(&bits);float signal[1280],pcm[640];unsigned n=160u<<mode;
  for(unsigned frame=0;frame<96;frame++){frame_context=frame;speex_bits_reset(&bits);for(unsigned j=0;j<n*(stereo+1);j++)signal[j]=(policy==2&&frame>15&&frame<75)?0.f:(float)(1400.*sin((frame*n+j)*.071)+(int)(next()%600)-300);if(stereo)speex_encode_stereo(signal,n,&bits);CHECK(speex_encode(encoder,signal,&bits)>=0);if(frame==47)CHECK(!speex_decoder_ctl(decoder,SPEEX_RESET_STATE,NULL));if(frame%23>=4&&frame%23<=6){CHECK(!speex_decode(decoder,NULL,pcm));losses++;}else{speex_bits_rewind(&bits);CHECK(!speex_decode(decoder,&bits,pcm));}for(unsigned j=0;j<n;j++)CHECK(isfinite(pcm[j]));codec_frames++;}
  speex_bits_destroy(&bits);speex_encoder_destroy(encoder);speex_decoder_destroy(decoder);
 }
}
int lamp_main(int argc,lamp_char**argv){
 (void)argc;(void)argv;CHECK(sizeof(Pitch)==80);pitch_vectors();innovation_vectors();noise_vectors();rejected();codec_calls();CHECK(pitch_mask==15&&shape_mask==255&&live_noise&&live_pitch&&live_forced&&live_innovation);
 printf("{\"result\":\"passed\",\"checks\":%llu,\"compared_float_words\":%llu,\"pitch_cases\":%llu,\"forced_cases\":%llu,\"innovation_cases\":%llu,\"noise_samples\":%llu,\"noise_mantissas_exhausted\":8388608,\"rejections\":%llu,",(unsigned long long)checks,(unsigned long long)words,(unsigned long long)pitch_cases,(unsigned long long)forced_cases,(unsigned long long)innovation_cases,(unsigned long long)noise_samples,(unsigned long long)rejections);
 printf("\"reference_codec_frames\":%llu,\"reference_losses\":%llu,\"pitch_kind_mask\":%u,\"innovation_book_mask\":%u,\"mirrored_calls\":{\"pitch\":%llu,\"forced_pitch\":%llu,\"innovation\":%llu,\"noise\":%llu},\"pcm_decoder_implemented\":false}\n",(unsigned long long)codec_frames,(unsigned long long)losses,pitch_mask,shape_mask,(unsigned long long)live_pitch,(unsigned long long)live_forced,(unsigned long long)live_innovation,(unsigned long long)live_noise);return 0;
}
