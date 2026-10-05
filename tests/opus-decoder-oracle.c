/* Development-only comparison with the complete normative BSD CELT decoder.
   celt.c is included unchanged to inspect its internal state after every frame. */
#include "lamp-test.h"
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "celt.c"

typedef struct {
 uint32_t magic; int channels,downsample; uint32_t rng; int error;
 int period,period_old; float gain,gain_old; int tap,tap_old;
 float deemph[2]; int last_pitch,loss; uint32_t reserved;
 float decode[2][2168],lpc[2][24],old[42],log[42],log2[42],background[42];
} LampState;
typedef struct {
 LampState *state; const unsigned char *data; float *pcm; ec_dec *ec; void *work;
 unsigned len; int channels,lm,start,end; unsigned pcm_cap,work_cap,state_cap;
} Frame;
typedef char state_layout_check[(sizeof(LampState)==18272&&offsetof(LampState,old)==17600)?1:-1];
typedef char frame_layout_check[(sizeof(Frame)==72&&offsetof(Frame,len)==40)?1:-1];
LAMP_ABI int op_celt_decoder_init(LampState *,unsigned,int,int);
LAMP_ABI int op_celt_decode_frame(Frame *);
static uint32_t random_state=0x017c3b49;
static uint32_t random_next(void){random_state^=random_state<<13;random_state^=random_state>>17;random_state^=random_state<<5;return random_state;}
static unsigned frame_checks,real_checks,invalid_checks,silent_checks,transient_checks,postfilter_checks,anti_checks,primed_checks,rejected_checks,loss_checks,pitch_loss_checks,noise_loss_checks;
static unsigned long long coefficients;
static float max_error,max_pcm_error;
typedef struct {uint64_t before; LampState value; uint64_t after;} StateGuard;
typedef struct {uint64_t before; unsigned char value[44048]; uint64_t after;} WorkGuard;
typedef struct {uint64_t before; float value[1920]; uint64_t after;} PcmGuard;
static StateGuard state;
static WorkGuard work;
static PcmGuard pcm;
static CELTDecoder *reference;
static float expected_pcm[1920];
static int permit_entropy_failure;
static const uint64_t before_guard=0x13579bdf98765432ULL,after_guard=0x2468ace012345678ULL;
static int compare_values(const char *kind,const float *a,const float *b,int n,int pcm_values){
 for(int i=0;i<n;i++){
  float error=fabsf(a[i]-b[i]),scale=fmaxf(1.f,fabsf(a[i]));
  if(!isfinite(a[i])||!isfinite(b[i])||error>0.00004f*scale){printf("%s[%d] mismatch expected=%.9g actual=%.9g error=%.9g frame=%u\n",kind,i,a[i],b[i],error,frame_checks);return 0;}
  if(error/scale>max_error)max_error=error/scale;
  if(pcm_values&&error>max_pcm_error)max_pcm_error=error;
  coefficients++;
 }
 return 1;
}
static int reset(int CC,int rate){
 if(reference)free(reference);
 reference=(CELTDecoder*)calloc(1,celt_decoder_get_size(CC));
 if(!reference||celt_decoder_init(reference,rate,CC)!=OPUS_OK)return 0;
 celt_decoder_ctl(reference,CELT_SET_SIGNALLING(0));
 memset(&state,0xa5,sizeof(state));state.before=before_guard;state.after=after_guard;
 if(!op_celt_decoder_init(&state.value,sizeof(LampState),CC,rate))return 0;
 if(state.before!=before_guard||state.after!=after_guard)return 0;
 return 1;
}
static int decode(const unsigned char *payload,unsigned len,int C,int LM,int start,int end,unsigned prime){
 int N=120<<LM,CC=reference->channels,down=reference->downsample;
 int lost=payload==NULL||len<=1,noise=reference->loss_count>=5||start!=0;
 celt_decoder_ctl(reference,CELT_SET_CHANNELS(C));
 celt_decoder_ctl(reference,CELT_SET_START_BAND(start));
 celt_decoder_ctl(reference,CELT_SET_END_BAND(end));
 ec_dec ea,eb;memset(&ea,0,sizeof(ea));memset(&eb,0,sizeof(eb));
 if(lost){memset(&ea,0xa5,sizeof(ea));eb=ea;}
 if(prime){
  ec_dec_init(&ea,(unsigned char*)payload,len);
  for(unsigned i=0;i<prime;i++)ec_dec_bit_logp(&ea,2+i%7);
  eb=ea;
 }
 memset(&pcm,0xa5,sizeof(pcm));pcm.before=before_guard;pcm.after=after_guard;
 memset(&work,0xa5,sizeof(work));work.before=before_guard;work.after=after_guard;
 Frame request={&state.value,payload,pcm.value,prime||lost?&eb:NULL,work.value,len,C,LM,start,end,1920,44048,sizeof(LampState)},backup=request;
 int a=celt_decode_with_ec(reference,payload,len,expected_pcm,N/down,prime||lost?&ea:NULL);
 int b=op_celt_decode_frame(&request);
 if(permit_entropy_failure&&(a==OPUS_INTERNAL_ERROR||reference->error)){
  if(b!=-1||state.value.error!=1||memcmp(&request,&backup,sizeof(request))||state.before!=before_guard||state.after!=after_guard||pcm.before!=before_guard||pcm.after!=after_guard||work.before!=before_guard||work.after!=after_guard){puts("Late entropy rejection mismatch");return 0;}
  LampState saved_state=state.value;WorkGuard saved_work=work;PcmGuard saved_pcm=pcm;ec_dec saved_ec=eb;
  if(op_celt_decode_frame(&request)!=0||memcmp(&state.value,&saved_state,sizeof(saved_state))||memcmp(&work,&saved_work,sizeof(work))||memcmp(&pcm,&saved_pcm,sizeof(pcm))||memcmp(&eb,&saved_ec,sizeof(eb))){puts("Failed frame state was reused");return 0;}
  rejected_checks++;return 1;
 }
 if(a!=b){printf("Frame result mismatch a=%d b=%d len=%u C=%d CC=%d LM=%d bands=%d..%d down=%d prime=%u frame=%u referr=%d asmerr=%d\n",a,b,len,C,CC,LM,start,end,down,prime,frame_checks,reference->error,state.value.error);return 0;}
 if(a<=0||reference->error||state.value.error)return 0;
 if(memcmp(&request,&backup,sizeof(request))||state.before!=before_guard||state.after!=after_guard||pcm.before!=before_guard||pcm.after!=after_guard||work.before!=before_guard||work.after!=after_guard)return 0;
 for(int i=(N/down)*CC;i<1920;i++){uint32_t v;memcpy(&v,pcm.value+i,4);if(v!=0xa5a5a5a5)return 0;}
 if((prime||lost)&&memcmp(&ea,&eb,sizeof(ea))){puts("Primed/ignored entropy mismatch");return 0;}
 if(state.value.rng!=reference->rng||state.value.period!=reference->postfilter_period||state.value.period_old!=reference->postfilter_period_old||state.value.gain!=reference->postfilter_gain||state.value.gain_old!=reference->postfilter_gain_old||state.value.tap!=reference->postfilter_tapset||state.value.tap_old!=reference->postfilter_tapset_old||state.value.loss!=reference->loss_count||state.value.last_pitch!=reference->last_pitch_index){printf("Decoder scalar state mismatch loss=%d/%d pitch=%d/%d rng=%u/%u\n",reference->loss_count,state.value.loss,reference->last_pitch_index,state.value.last_pitch,reference->rng,state.value.rng);return 0;}
 float *lpc=reference->_decode_mem+CC*2168,*old=lpc+CC*24;
 if(!compare_values("PCM",expected_pcm,pcm.value,(N/down)*CC,1)||!compare_values("decode history",reference->_decode_mem,state.value.decode[0],CC*2168,0)||!compare_values("LPC histories",lpc,state.value.lpc[0],CC*24,0)||!compare_values("energy histories",old,state.value.old,168,0)||!compare_values("deemphasis",reference->preemph_memD,state.value.deemph,2,0))return 0;
 if(lost){loss_checks++;if(noise)noise_loss_checks++;else pitch_loss_checks++;frame_checks++;return 1;}
 int *controls=(int*)(work.value+64+80);
 if(controls[0])silent_checks++;
 if(controls[1])transient_checks++;
 if(controls[4])postfilter_checks++;
 if(*(int*)(work.value+64+112))anti_checks++;
 if(prime)primed_checks++;
 frame_checks++;return 1;
}
static int fixture(const char *filename){
 FILE *f=fopen(filename,"rb");if(!f)return 0;
 unsigned char data[8192],packet[4096];size_t len=fread(data,1,sizeof(data),f),at=0,packet_len=0;fclose(f);
 if(!reset(2,48000))return 0;
 while(at<len){
  if(len-at<27||memcmp(data+at,"OggS",4))return 0;
  unsigned segments=data[at+26];if(len-at<27+segments)return 0;
  size_t body=at+27+segments;
  for(unsigned i=0;i<segments;i++){
   unsigned count=data[at+27+i];if(body+count>len||packet_len+count>sizeof(packet))return 0;
   memcpy(packet+packet_len,data+body,count);packet_len+=count;body+=count;
   if(count<255){
    if(packet_len&&((packet[0]>>3)>=16)&&memcmp(packet,"OpusHead",packet_len<8?packet_len:8)&&memcmp(packet,"OpusTags",packet_len<8?packet_len:8)){
     /* The fixture uses one CELT frame per packet; verify framing explicitly. */
     if((packet[0]&3)!=0)return 0;
     const int ends[4]={13,17,19,21};
     if(!decode(packet+1,(unsigned)packet_len-1,1+((packet[0]>>2)&1),(packet[0]>>3)&3,0,ends[(packet[0]>>5)&3],0))return 0;
     real_checks++;
    }
    packet_len=0;
   }
  }
  at=body;
 }
 return !packet_len&&real_checks==13;
}
#define VECTOR_COUNT 1024
typedef struct {unsigned char payload[1275];unsigned len,prime;int C,LM,start,end;} Vector;
static Vector vectors[VECTOR_COUNT];
static int encoded_vectors(void){
 CELTEncoder *enc[2];float source[1920];
 for(int C=1;C<=2;C++){
  enc[C-1]=(CELTEncoder*)calloc(1,celt_encoder_get_size(C));
  if(!enc[C-1]||celt_encoder_init(enc[C-1],48000,C)!=OPUS_OK)return 0;
  celt_encoder_ctl(enc[C-1],CELT_SET_SIGNALLING(0));
 }
 const int lengths[8]={2,3,8,16,32,64,256,1275},ends[4]={13,17,19,21};
 for(unsigned k=0;k<VECTOR_COUNT;k++){
  Vector *v=vectors+k;
  v->C=1+((k/4)%2);v->LM=k%4;v->end=ends[(k/8)%4];v->start=(k/256)%2?17:0;
  if(v->start>=v->end)v->start=0;
  v->prime=k%11==0?1+k%5:0;
  int N=120<<v->LM,target=lengths[(k/32)%8],signal=(k/16)%8;
  for(int i=0;i<N;i++)for(int c=0;c<v->C;c++){
   double t=(k*960+i)/48000.;
   float value;
   switch(signal){
    case 0:value=0;break;
    case 1:value=(float)(.2*sin(2*3.141592653589793*(110+55*c)*t));break;
    case 2:value=(float)(.4*sin(2*3.141592653589793*(400+1300*c)*t));break;
    case 3:value=((int)(random_next()&65535)-32768)*(0.25f/32768.f);break;
    case 4:value=i==N/2?.95f:0;break;
    case 5:value=(float)(.5*sin(2*3.141592653589793*(1000+60*c)*t))*(i>N/2);break;
    case 6:value=(i%17)<8?.2f:-.2f;break;
    default:value=(float)(.04*sin(2*3.141592653589793*12000*t)+.2*sin(2*3.141592653589793*200*t));break;
   }
   source[i*v->C+c]=value;
  }
  CELTEncoder *encoder=enc[v->C-1];
  celt_encoder_ctl(encoder,CELT_SET_START_BAND(v->start));
  celt_encoder_ctl(encoder,CELT_SET_END_BAND(v->end));
  celt_encoder_ctl(encoder,CELT_SET_PREDICTION(k%13==0?0:2));
  ec_enc ec,*ep=NULL;
  if(v->prime){ec_enc_init(&ec,v->payload,target);ep=&ec;for(unsigned i=0;i<v->prime;i++)ec_enc_bit_logp(ep,(k+i)&1,2+i%7);}
  int len=celt_encode_with_ec(encoder,source,N,v->payload,target,ep);
  if(len<2){printf("Encoder failed %d vector=%u\n",len,k);return 0;}
  v->len=len;
 }
 free(enc[0]);free(enc[1]);
 const int rates[5]={48000,24000,16000,12000,8000};
 for(int CC=1;CC<=2;CC++)for(unsigned rate=0;rate<5;rate++){
  if(!reset(CC,rates[rate]))return 0;
  for(unsigned k=0;k<VECTOR_COUNT;k++){
   Vector *v=vectors+k;
   if(!decode(v->payload,v->len,v->C,v->LM,v->start,v->end,v->prime)){printf("Encoded vector %u\n",k);return 0;}
   if(k%63==0){
    for(int loss=0;loss<9;loss++){
     unsigned char empty=0;
     if(!decode(loss%3==0?NULL:&empty,loss%3==2?1:0,v->C,(v->LM+loss)%4,v->start,v->end,0)){printf("Loss vector %u burst=%d\n",k,loss);return 0;}
    }
   }
  }
 }
 return 1;
}
static int initial_and_highband_loss(void){
 const int rates[5]={48000,24000,16000,12000,8000},ends[4]={13,17,19,21};
 for(int CC=1;CC<=2;CC++)for(int rate=0;rate<5;rate++)for(int LM=0;LM<4;LM++)for(int band=0;band<4;band++){
  if(!reset(CC,rates[rate]))return 0;
  for(int loss=0;loss<8;loss++){
   unsigned char empty=0;
   if(!decode(loss%2?&empty:NULL,loss%2?1:16,CC,LM,0,ends[band],0))return 0;
  }
  Vector *v=vectors+512+LM+8*band;
  if(!decode(v->payload,v->len,v->C,v->LM,v->start,v->end,v->prime))return 0;
  for(int loss=0;loss<8;loss++)if(!decode(NULL,0,CC,(LM+loss)%4,17,21,0))return 0;
  if(!decode(v->payload,v->len,v->C,v->LM,v->start,v->end,v->prime))return 0;
 }
 return 1;
}
static int malformed(void){
 const int rates[5]={48000,24000,16000,12000,8000},ends[4]={13,17,19,21};
 unsigned char payload[1275];permit_entropy_failure=1;
 for(unsigned k=0;k<8192;k++){
  if(!reset(1+k%2,rates[(k/2)%5]))return 0;
  int C=1+(k/10)%2,LM=(k/20)%4,end=ends[(k/80)%4],start=k%3==0&&end>17?17:0;
  unsigned len;
  if(k<4096){
   len=2+random_next()%1274;
   if(k%4==0)len=2+k%16;
   for(unsigned i=0;i<len;i++)payload[i]=(unsigned char)random_next();
  }else{
   Vector *v=vectors+k%VECTOR_COUNT;len=v->len;C=v->C;LM=v->LM;start=v->start;end=v->end;
   memcpy(payload,v->payload,len);
   if(k%2&&len>2)len=2+random_next()%(len-1);
   else for(unsigned i=0;i<1+k%7;i++)payload[random_next()%len]^=1u<<(random_next()%8);
  }
  if(!decode(payload,len,C,LM,start,end,0)){printf("Malformed/truncated case %u\n",k);return 0;}
  if(!reset(1+k%2,rates[(k/2)%5]))return 0;
  /* Reset after rejection must restore a usable decoder. */
  Vector *v=vectors+(k%VECTOR_COUNT);
  if(!decode(v->payload,v->len,v->C,v->LM,v->start,v->end,v->prime))return 0;
 }
 permit_entropy_failure=0;return rejected_checks>0;
}
static int invalid(void){
 if(!reset(2,48000))return 0;
 unsigned char payload[16]={0};ec_dec ec;memset(&ec,0,sizeof(ec));ec_dec_init(&ec,payload,16);
 Frame good={&state.value,payload,pcm.value,&ec,work.value,16,2,3,0,21,1920,44048,sizeof(LampState)};
 for(unsigned k=0;k<52;k++){
  Frame r=good;LampState initial=state.value;ec_dec initial_ec=ec;
  switch(k){
   case 0:r.state=NULL;break;case 1:state.value.lpc[1][23]=NAN;break;case 2:r.pcm=NULL;break;case 3:r.work=NULL;break;
   case 4:r.len=0;state.value.loss=1;state.value.last_pitch=99;break;case 5:r.len=1;state.value.loss=1;state.value.last_pitch=721;break;case 6:r.len=1276;break;
   case 7:r.channels=0;break;case 8:r.channels=3;break;case 9:r.lm=-1;break;case 10:r.lm=4;break;
   case 11:r.start=-1;break;case 12:r.start=21;break;case 13:r.end=0;break;case 14:r.end=22;break;case 15:r.start=17;r.end=17;break;
   case 16:r.pcm_cap=1919;break;case 17:r.work_cap=44047;break;case 18:r.state_cap=18271;break;
   case 19:state.value.magic=0;break;case 20:state.value.error=1;break;case 21:state.value.channels=0;break;case 22:state.value.channels=3;break;
   case 23:state.value.downsample=0;break;case 24:state.value.downsample=5;break;case 25:state.value.period=1023;break;case 26:state.value.period_old=-1;break;
   case 27:state.value.tap=3;break;case 28:state.value.tap_old=-1;break;case 29:state.value.gain=-.1f;break;case 30:state.value.gain_old=1.01f;break;
   case 31:state.value.decode[1][2167]=INFINITY;break;case 32:state.value.old[41]=NAN;break;case 33:state.value.deemph[1]=INFINITY;break;
   case 34:ec.buf=NULL;break;case 35:ec.storage=15;break;case 36:ec.offs=17;break;case 37:ec.end_offs=17;break;
   case 38:ec.rng=0;break;case 39:ec.rng=0x80000001;break;case 40:ec.nend_bits=33;break;case 41:ec.nbits_total=32769;break;
   case 42:state.value.log2[41]=161;break;case 43:state.value.background[41]=-161;break;case 44:state.value.downsample=-1;break;case 45:r.len=-1;break;
   case 46:state.value.loss=-1;break;case 47:state.value.loss=0x7fffffff;break;
   case 48:r.data=NULL;state.value.deemph[1]=NAN;break;
   case 49:r.data=NULL;state.value.lpc[0][23]=INFINITY;break;
   case 50:r.data=NULL;state.value.loss=2;state.value.last_pitch=-1;break;
   case 51:state.value.lpc[1][23]=1e20f;break;
  }
  Frame saved=r;LampState saved_state=state.value;ec_dec saved_ec=ec;
  WorkGuard saved_work=work;PcmGuard saved_pcm=pcm;
  if(op_celt_decode_frame(&r)!=0||memcmp(&r,&saved,sizeof(r))||memcmp(&state.value,&saved_state,sizeof(saved_state))||memcmp(&ec,&saved_ec,sizeof(ec))||memcmp(&work,&saved_work,sizeof(work))||memcmp(&pcm,&saved_pcm,sizeof(pcm))){printf("Invalid guard %u failed\n",k);return 0;}
  state.value=initial;ec=initial_ec;invalid_checks++;
 }
 if(op_celt_decode_frame(NULL)||op_celt_decoder_init(NULL,sizeof(LampState),2,48000))return 0;
 invalid_checks+=2;
 for(int k=0;k<5;k++){
  LampState saved=state.value;
  if(op_celt_decoder_init(&state.value,k==0?18271:18272,k==1?0:k==2?3:2,k==3?44100:k==4?0:48000)||memcmp(&saved,&state.value,sizeof(saved)))return 0;
  invalid_checks++;
 }
 return 1;
}
int main(int argc,char **argv){
 if(argc!=2||!fixture(argv[1])||!encoded_vectors()||!initial_and_highband_loss()||!malformed()||!invalid())return 1;
 printf("CELT decoder: %u stateful frames (%u real, %u silent, %u transient, %u postfilter, %u anti-reserved, %u primed, %u concealed: %u pitch and %u noise), %u strict entropy rejections with sticky failure/reset, %llu PCM/history coefficients, %u guards; max scaled error %.9g, max PCM error %.9g\n",frame_checks,real_checks,silent_checks,transient_checks,postfilter_checks,anti_checks,primed_checks,loss_checks,pitch_loss_checks,noise_loss_checks,rejected_checks,coefficients,invalid_checks,max_error,max_pcm_error);
 free(reference);return 0;
}
