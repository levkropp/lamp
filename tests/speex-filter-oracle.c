/* Test-only differential/guarded Speex LPC and filter checks. The C decoder
   remains the reference; actual calls are intercepted by generated wrappers.
   No reference C or this oracle is linked into either LAMP player. */
#include "lamp-test.h"
#include <math.h>
#include <float.h>
#include "speex/speex.h"
#include "speex/speex_stereo.h"
#include "speex-filter-test.h"
LAMP_ABI int spx_lsp_interpolate(const float*,const float*,float*,unsigned,unsigned,unsigned,float);
LAMP_ABI int spx_lsp_to_lpc(const float*,float*,unsigned,unsigned);
LAMP_ABI int spx_bw_lpc(const float*,float*,unsigned,float);
LAMP_ABI int spx_iir_mem(const float*,const float*,float*,unsigned,unsigned,float*);
LAMP_ABI int spx_highpass(const float*,float*,unsigned,unsigned,float*);
static uint64_t checks,interpolation_cases,lpc_cases,bw_cases,iir_cases,hp_cases,rejections,words,codec_frames,losses,resets;
static uint64_t live_lpc,live_interpolate,live_bw,live_iir,live_hp,live_samples;
static uint64_t finite_edge_vectors;
static unsigned mode_context,quality_context,frame_context;
static uint32_t rng=0x38319a27;
static char reference_scratch[8192]; /* original C pseudo-stack, test-only */
static uint32_t next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"line %d mode=%u quality=%u frame=%u: %s\n",__LINE__,mode_context,quality_context,frame_context,#x);exit(1);}}while(0)
typedef struct {unsigned char*allocation,*data;size_t size;} Guard;
static Guard guarded(size_t n){SYSTEM_INFO info;GetSystemInfo(&info);size_t page=info.dwPageSize,body=(n+page-1)/page*page;if(!body)body=page;Guard g={0};DWORD old;g.allocation=VirtualAlloc(NULL,body+page*2,MEM_RESERVE|MEM_COMMIT,PAGE_NOACCESS);CHECK(g.allocation&&VirtualProtect(g.allocation+page,body,PAGE_READWRITE,&old));g.data=g.allocation+page+body-n;g.size=n;return g;}
static void release(Guard*g){CHECK(VirtualFree(g->allocation,0,MEM_RELEASE));}
static void canary(const Guard*g){for(unsigned j=0;j<32;j++)CHECK(g->data[j]==0xa5);}
static void unchanged(const Guard*g){for(size_t j=0;j<g->size;j++)CHECK(g->data[j]==0xa5);}
static float*values(Guard*g){return(float*)(g->data+32);}
static void exact(const float*a,const float*b,unsigned n,const char*label){
 for(unsigned i=0;i<n;i++){uint32_t x,y;memcpy(&x,a+i,4);memcpy(&y,b+i,4);if(x!=y){fprintf(stderr,"%s coefficient/sample %u: reference=%a/%08x assembly=%a/%08x mode=%u quality=%u frame=%u\n",label,i,(double)a[i],x,(double)b[i],y,mode_context,quality_context,frame_context);exit(1);}CHECK(x==y);}words+=n;
}
/* These callbacks receive actual full-reference codec calls. Save inputs
   before the reference changes any in-place destination, then compare the
   assembly result and every persistent filter-memory word independently. */
void test_speex_lpc(SpxRefLpc ref,const float*f,float*a,int n,char*s){float input[10],actual[10];CHECK(n==8||n==10);memcpy(input,f,n*4);ref(f,a,n,s);CHECK(spx_lsp_to_lpc(input,actual,n,n));exact(a,actual,n,"live LPC");live_lpc++;}
void test_speex_interpolate(SpxRefInterpolate ref,float*a,float*b,float*c,int n,int sub,int total,float margin){float old[10],current[10],actual[10];CHECK(n==8||n==10);memcpy(old,a,n*4);memcpy(current,b,n*4);ref(a,b,c,n,sub,total,margin);CHECK(spx_lsp_interpolate(old,current,actual,n,sub,total,margin));exact(c,actual,n,"live interpolation");live_interpolate++;}
void test_speex_bw(SpxRefBw ref,float gamma,const float*a,float*b,int n){float input[10],actual[10];CHECK(n==8||n==10);memcpy(input,a,n*4);ref(gamma,a,b,n);CHECK(spx_bw_lpc(input,actual,n,gamma));exact(b,actual,n,"live bandwidth");live_bw++;}
void test_speex_iir(SpxRefIir ref,const float*x,const float*a,float*y,int n,int order,float*mem,char*s){float input[640],coeff[10],state[10],actual[640];CHECK(n>=0&&n<=640&&(order==8||order==10));memcpy(input,x,n*4);memcpy(coeff,a,order*4);memcpy(state,mem,order*4);ref(x,a,y,n,order,mem,s);CHECK(spx_iir_mem(input,coeff,actual,n,order,state));exact(y,actual,n,"live IIR output");exact(mem,state,order,"live IIR history");live_iir++;live_samples+=n;}
void test_speex_highpass(SpxRefHighpass ref,const float*x,float*y,int n,int id,float*mem){float input[640],state[2],actual[640];CHECK(n>=0&&n<=640&&id>=0&&id<=4);memcpy(input,x,n*4);memcpy(state,mem,8);ref(x,y,n,id,mem);CHECK(spx_highpass(input,actual,n,id,state));exact(y,actual,n,"live high-pass output");exact(mem,state,2,"live high-pass history");live_hp++;live_samples+=n;}
static void lsp_vectors(void){
 for(unsigned order=8;order<=10;order+=2){
  Guard old=guarded(order*4),current=guarded(order*4),output=guarded(order*4+32);float expected[10],copy[10];
  for(unsigned trial=0;trial<16384;trial++){
   unsigned total=1+next()%64,sub=next()%total;float margin=(trial%3==0)?.002f:(trial%3==1)?.05f:.25f;
   for(unsigned j=0;j<order;j++){((float*)old.data)[j]=((int)(next()%64001)-32000)/2048.f;((float*)current.data)[j]=((int)(next()%64001)-32000)/2048.f;}
   spxref_lsp_interpolate((float*)old.data,(float*)current.data,expected,order,sub,total,margin);memset(output.data,0xa5,output.size);CHECK(spx_lsp_interpolate((float*)old.data,(float*)current.data,values(&output),order,sub,total,margin));exact(expected,values(&output),order,"interpolation");canary(&output);interpolation_cases++;
   memcpy(copy,old.data,order*4);CHECK(spx_lsp_interpolate(copy,(float*)current.data,copy,order,sub,total,margin));exact(expected,copy,order,"in-place interpolation");
   /* Monotone random angles exercise the codec approximation around pi/2,
      endpoints and the complete polynomial reconstruction. */
   for(unsigned j=0;j<order;j++)((float*)old.data)[j]=(float)((j+(next()%1024)/1024.)*3.14159265358979323846/order);
   if(trial%8==0)((float*)old.data)[0]=0.f;if(trial%8==1)((float*)old.data)[order-1]=3.14159265358979323846f;if(trial%8==2)((float*)old.data)[order/2]=1.57079632679489661923f;
   spxref_lsp_to_lpc((float*)old.data,expected,order,reference_scratch);memset(output.data,0xa5,output.size);CHECK(spx_lsp_to_lpc((float*)old.data,values(&output),order,order));exact(expected,values(&output),order,"LPC");canary(&output);lpc_cases++;
   memcpy(copy,old.data,order*4);CHECK(spx_lsp_to_lpc(copy,copy,order,order));exact(expected,copy,order,"in-place LPC");
   float gamma=(trial%8==0)?0.f:(trial%8==1)?1.f:(float)(next()%65537)/65536.f;spxref_bw_lpc(gamma,expected,copy,order);memcpy(current.data,expected,order*4);memset(output.data,0xa5,output.size);CHECK(spx_bw_lpc((float*)current.data,values(&output),order,gamma));exact(copy,values(&output),order,"bandwidth");canary(&output);bw_cases++;
   CHECK(spx_bw_lpc((float*)current.data,(float*)current.data,order,gamma));exact(copy,(float*)current.data,order,"in-place bandwidth");
  }
  release(&old);release(&current);release(&output);
 }
}
static void filter_vectors(void){
 const unsigned lengths[]={1,2,3,17,39,40,41,79,80,81,127,159,160,161,319,320,321,639,640};
 for(unsigned order=8;order<=10;order+=2)for(unsigned trial=0;trial<512;trial++){
  float freq[10],coef[10],expected[640],expected_state[10],chunked[640],chunk_state[10];for(unsigned j=0;j<order;j++)freq[j]=(float)((j+1+((int)(next()%1025)-512)/2048.)*3.14159265358979323846/(order+1));spxref_lsp_to_lpc(freq,coef,order,reference_scratch);spxref_bw_lpc(.8f,coef,coef,order);
  for(unsigned item=0;item<sizeof(lengths)/sizeof(*lengths);item++){
   unsigned n=lengths[item];Guard input=guarded(n*4),coeff=guarded(order*4),state=guarded(order*4+32),output=guarded(n*4+32);memcpy(coeff.data,coef,order*4);
   memset(state.data,0xa5,state.size);for(unsigned j=0;j<order;j++)expected_state[j]=((int)(next()%2001)-1000)/128.f;memcpy(values(&state),expected_state,order*4);memcpy(chunk_state,expected_state,order*4);
   for(unsigned j=0;j<n;j++)((float*)input.data)[j]=((int)(next()%65537)-32768)/2.f;
   spxref_iir_mem16((float*)input.data,coef,expected,n,order,expected_state,NULL);memset(output.data,0xa5,output.size);CHECK(spx_iir_mem((float*)input.data,(float*)coeff.data,values(&output),n,order,values(&state)));exact(expected,values(&output),n,"IIR");exact(expected_state,values(&state),order,"IIR history");canary(&state);canary(&output);iir_cases++;
   unsigned split=next()%(n+1);CHECK(spx_iir_mem((float*)input.data,coef,chunked,split,order,chunk_state));CHECK(spx_iir_mem((float*)input.data+split,coef,chunked+split,n-split,order,chunk_state));exact(expected,chunked,n,"split IIR");exact(expected_state,chunk_state,order,"split IIR history");
   /* Exact in-place input/output uses the same preceding state. */
   memcpy(chunk_state,values(&state),order*4);spxref_iir_mem16((float*)input.data,coef,expected,n,order,expected_state,NULL);CHECK(spx_iir_mem((float*)input.data,coef,(float*)input.data,n,order,values(&state)));exact(expected,(float*)input.data,n,"in-place IIR");exact(expected_state,values(&state),order,"in-place IIR history");
   release(&input);release(&coeff);release(&state);release(&output);
  }
 }
 for(unsigned id=0;id<5;id++)for(unsigned trial=0;trial<64;trial++)for(unsigned item=0;item<sizeof(lengths)/sizeof(*lengths);item++){
  unsigned n=lengths[item];Guard input=guarded(n*4),output=guarded(n*4+32),state=guarded(8+32);float expected[640],chunked[640],expected_state[2],chunk_state[2];memset(state.data,0xa5,state.size);for(unsigned j=0;j<2;j++)expected_state[j]=((int)(next()%2001)-1000)/128.f;memcpy(values(&state),expected_state,8);memcpy(chunk_state,expected_state,8);for(unsigned j=0;j<n;j++)((float*)input.data)[j]=((int)(next()%65537)-32768)/2.f;
  spxref_highpass((float*)input.data,expected,n,id,expected_state);memset(output.data,0xa5,output.size);CHECK(spx_highpass((float*)input.data,values(&output),n,id,values(&state)));exact(expected,values(&output),n,"high-pass");exact(expected_state,values(&state),2,"high-pass history");canary(&output);canary(&state);hp_cases++;
  unsigned split=next()%(n+1);CHECK(spx_highpass((float*)input.data,chunked,split,id,chunk_state));CHECK(spx_highpass((float*)input.data+split,chunked+split,n-split,id,chunk_state));exact(expected,chunked,n,"split high-pass");exact(expected_state,chunk_state,2,"split high-pass history");
  spxref_highpass((float*)input.data,expected,n,id,expected_state);CHECK(spx_highpass((float*)input.data,(float*)input.data,n,id,values(&state)));exact(expected,(float*)input.data,n,"in-place high-pass");exact(expected_state,values(&state),2,"in-place high-pass history");release(&input);release(&output);release(&state);
 }
 CHECK(spx_iir_mem(NULL,NULL,NULL,0,10,NULL));CHECK(spx_highpass(NULL,NULL,0,4,NULL));
}
static void bad_arguments(void){
 const uint32_t specials[]={0x7f800000,0xff800000,0x7fc12345,0x7f800001};
 for(unsigned order=8;order<=10;order+=2){
  Guard source=guarded(order*4),other=guarded(order*4),output=guarded(order*4+32),state=guarded(order*4+32),signal=guarded(640*4);float*input=(float*)source.data,*current=(float*)other.data;for(unsigned j=0;j<order;j++)input[j]=current[j]=(j+1)*.25f;
  for(unsigned k=0;k<sizeof(specials)/sizeof(*specials);k++)for(unsigned position=0;position<order;position++){
   float saved=input[position];memcpy(input+position,specials+k,4);memset(output.data,0xa5,output.size);CHECK(!spx_lsp_to_lpc(input,values(&output),order,order));unchanged(&output);CHECK(!spx_lsp_interpolate(input,current,values(&output),order,0,4,.002f));unchanged(&output);CHECK(!spx_bw_lpc(input,values(&output),order,.93f));unchanged(&output);input[position]=saved;rejections+=3;
  }
  memset(output.data,0xa5,output.size);CHECK(!spx_lsp_to_lpc(input,values(&output),order,order-1));CHECK(!spx_lsp_to_lpc(NULL,values(&output),order,order));CHECK(!spx_lsp_to_lpc((float*)(UINTPTR_MAX-7),values(&output),order,order));CHECK(!spx_lsp_to_lpc(input,values(&output),9,order));CHECK(!spx_lsp_interpolate(input,current,values(&output),order,4,4,.002f));CHECK(!spx_lsp_interpolate(input,current,values(&output),order,0,0,.002f));CHECK(!spx_lsp_interpolate(input,current,values(&output),order,0,65,.002f));CHECK(!spx_lsp_interpolate(input,current,values(&output),order,0,4,-.1f));CHECK(!spx_lsp_interpolate(input,current,values(&output),order,0,4,.3f));CHECK(!spx_bw_lpc(input,values(&output),order,1.1f));CHECK(!spx_bw_lpc(input,values(&output),order,-.1f));unchanged(&output);rejections+=11;
  float coefficients[10]={0},memory[10]={0},saved[10];memset(signal.data,0,signal.size);Guard samples=guarded(640*4+32);memset(samples.data,0xa5,samples.size);
  for(unsigned k=0;k<sizeof(specials)/sizeof(*specials);k++){
   memcpy(signal.data+639*4,specials+k,4);CHECK(!spx_iir_mem((float*)signal.data,coefficients,values(&samples),640,order,memory));CHECK(!spx_highpass((float*)signal.data,values(&samples),640,1,memory));unchanged(&samples);memset(signal.data+639*4,0,4);rejections+=2;
   memcpy(coefficients+order-1,specials+k,4);CHECK(!spx_iir_mem((float*)signal.data,coefficients,values(&samples),640,order,memory));unchanged(&samples);coefficients[order-1]=0;rejections++;
   memcpy(memory+order-1,specials+k,4);memcpy(saved,memory,order*4);CHECK(!spx_iir_mem((float*)signal.data,coefficients,values(&samples),640,order,memory));CHECK(!memcmp(saved,memory,order*4));unchanged(&samples);memset(memory,0,sizeof(memory));rejections++;
  }
  CHECK(!spx_iir_mem((float*)signal.data,coefficients,values(&samples),641,order,memory));CHECK(!spx_iir_mem(NULL,coefficients,values(&samples),1,order,memory));CHECK(!spx_iir_mem((float*)(UINTPTR_MAX-7),coefficients,values(&samples),640,order,memory));CHECK(!spx_iir_mem((float*)signal.data,coefficients,(float*)signal.data+1,100,order,memory));CHECK(!spx_iir_mem((float*)signal.data,coefficients,values(&samples),1,order,coefficients));CHECK(!spx_highpass((float*)signal.data,values(&samples),1,5,memory));unchanged(&samples);rejections+=6;
  /* Delayed arithmetic overflow must roll back the whole block, including
     already computed earlier samples and persistent memory. */
  coefficients[0]=1e20f;((float*)signal.data)[620]=1.f;memcpy(saved,memory,order*4);CHECK(!spx_iir_mem((float*)signal.data,coefficients,values(&samples),640,order,memory));CHECK(!memcmp(saved,memory,order*4));unchanged(&samples);rejections++;
  ((float*)signal.data)[620]=FLT_MAX;CHECK(!spx_highpass((float*)signal.data,values(&samples),640,1,memory));CHECK(!memcmp(saved,memory,8));unchanged(&samples);rejections++;
  ((float*)signal.data)[620]=0.f;for(unsigned id=0;id<5;id++)for(unsigned position=0;position<2;position++){memcpy(memory+position,specials,4);memcpy(saved,memory,8);CHECK(!spx_highpass((float*)signal.data,values(&samples),640,id,memory));CHECK(!memcmp(saved,memory,8));unchanged(&samples);memset(memory,0,sizeof(memory));rejections++;}
  release(&samples);release(&source);release(&other);release(&output);release(&state);release(&signal);
 }
}
static void finite_edges(void){
 const uint32_t patterns[]={0,0x80000000,1,0x80000001,0x007fffff,0x807fffff,0x00800000,0x80800000};
 for(unsigned order=8;order<=10;order+=2)for(unsigned pattern=0;pattern<8;pattern++){
  float input[40],coeff[10],state[10],expected_state[10],out[40],expected[40],old[10],current[10],interpolated[10],margin;
  for(unsigned j=0;j<40;j++)memcpy(input+j,patterns+(pattern+j)%8,4);for(unsigned j=0;j<order;j++){coeff[j]=(j&1)?.03125f:-.0625f;memcpy(state+j,patterns+(pattern+j)%8,4);memcpy(old+j,patterns+1,4);memcpy(current+j,patterns+1,4);}memcpy(expected_state,state,order*4);
  spxref_iir_mem16(input,coeff,expected,40,order,expected_state,NULL);CHECK(spx_iir_mem(input,coeff,out,40,order,state));exact(expected,out,40,"finite-edge IIR");exact(expected_state,state,order,"finite-edge IIR state");finite_edge_vectors++;
  for(unsigned id=0;id<5;id++){memcpy(state,patterns+pattern,4);memcpy(state+1,patterns+(pattern+1)%8,4);memcpy(expected_state,state,8);spxref_highpass(input,expected,40,id,expected_state);CHECK(spx_highpass(input,out,40,id,state));exact(expected,out,40,"finite-edge high-pass");exact(expected_state,state,2,"finite-edge high-pass state");finite_edge_vectors++;}
  memcpy(&margin,patterns+1,4);spxref_lsp_interpolate(old,current,expected,order,0,1,margin);CHECK(spx_lsp_interpolate(old,current,interpolated,order,0,1,margin));exact(expected,interpolated,order,"negative-zero interpolation");finite_edge_vectors++;
  spxref_bw_lpc(margin,coeff,expected,order);CHECK(spx_bw_lpc(coeff,out,order,margin));exact(expected,out,order,"negative-zero bandwidth");finite_edge_vectors++;
 }
}
static void codec_calls(void){
 for(unsigned mode=0;mode<3;mode++)for(unsigned quality=0;quality<=10;quality++)for(unsigned stereo=0;stereo<2;stereo++)for(unsigned policy=0;policy<3;policy++){
  mode_context=mode;quality_context=quality;frame_context=0;const SpeexMode*m=speex_lib_get_mode(mode);void*encoder=speex_encoder_init(m),*decoder=speex_decoder_init(m);CHECK(encoder&&decoder);int q=quality,complexity=1,enabled=1;CHECK(!speex_encoder_ctl(encoder,SPEEX_SET_QUALITY,&q));CHECK(!speex_encoder_ctl(encoder,SPEEX_SET_COMPLEXITY,&complexity));if(policy==1)CHECK(!speex_encoder_ctl(encoder,SPEEX_SET_VBR,&enabled));if(policy==2){CHECK(!speex_encoder_ctl(encoder,SPEEX_SET_VAD,&enabled));CHECK(!speex_encoder_ctl(encoder,SPEEX_SET_DTX,&enabled));}
  SpeexBits bits;speex_bits_init(&bits);float input[1280],pcm[640];unsigned size=160u<<mode;
  for(unsigned frame=0;frame<96;frame++){
   frame_context=frame;speex_bits_reset(&bits);for(unsigned j=0;j<size*(stereo+1);j++)input[j]=(policy==2&&frame>15&&frame<75)?0.f:(float)(1400.*sin((frame*size+j)*.071)+(int)(next()%600)-300);
   if(stereo)speex_encode_stereo(input,size,&bits);CHECK(speex_encode(encoder,input,&bits)>=0);
   if(frame==47){CHECK(!speex_decoder_ctl(decoder,SPEEX_RESET_STATE,NULL));resets++;}
   if(frame==60||frame==90){int enhance=frame==90;CHECK(!speex_decoder_ctl(decoder,SPEEX_SET_ENH,&enhance));}
   if(frame%23>=4&&frame%23<=6){CHECK(!speex_decode(decoder,NULL,pcm));losses++;}else {speex_bits_rewind(&bits);CHECK(!speex_decode(decoder,&bits,pcm));}
   for(unsigned j=0;j<size;j++)CHECK(isfinite(pcm[j]));codec_frames++;
  }
  speex_bits_destroy(&bits);speex_encoder_destroy(encoder);speex_decoder_destroy(decoder);
 }
}
int lamp_main(int argc,lamp_char**argv){
 (void)argc;(void)argv;lsp_vectors();filter_vectors();bad_arguments();finite_edges();codec_calls();CHECK(live_lpc&&live_interpolate&&live_bw&&live_iir&&live_hp&&losses&&resets);
 printf("{\"finite_edge_vectors\":%llu,",(unsigned long long)finite_edge_vectors);
 printf("\"result\":\"passed\",\"checks\":%llu,\"compared_float_words\":%llu,",(unsigned long long)checks,(unsigned long long)words);
 printf("\"interpolation_cases\":%llu,\"lpc_cases\":%llu,\"bandwidth_cases\":%llu,\"iir_cases\":%llu,\"highpass_cases\":%llu,",(unsigned long long)interpolation_cases,(unsigned long long)lpc_cases,(unsigned long long)bw_cases,(unsigned long long)iir_cases,(unsigned long long)hp_cases);
 printf("\"rejections\":%llu,\"reference_codec_frames\":%llu,\"reference_losses\":%llu,\"reference_resets\":%llu,",(unsigned long long)rejections,(unsigned long long)codec_frames,(unsigned long long)losses,(unsigned long long)resets);
 printf("\"mirrored_calls\":{\"interpolation\":%llu,\"lpc\":%llu,\"bandwidth\":%llu,\"iir\":%llu,\"highpass\":%llu,\"filter_samples\":%llu},\"pcm_decoder_implemented\":false}\n",(unsigned long long)live_interpolate,(unsigned long long)live_lpc,(unsigned long long)live_bw,(unsigned long long)live_iir,(unsigned long long)live_hp,(unsigned long long)live_samples);return 0;
}
