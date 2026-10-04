/* Test-only normative decoder resampling, with reusable verified core harness. */
#define main silk_synthesis_oracle_main
#include "opus-silk-synthesis-oracle.c"
#undef main
#include "resampler_private.h"
#include <stddef.h>
typedef struct {int32_t *state;int16_t *out;const int16_t *in;unsigned n,state_cap,out_cap,in_cap;} Up2;
typedef struct {int32_t *state,*out;const int16_t *in,*coef;unsigned n,state_cap,out_cap,in_cap,coef_cap;} Ar2;
typedef struct {silk_resampler_state_struct *state;int in,out;unsigned cap;} ResampleInit;
typedef struct {silk_resampler_state_struct *state;int16_t *out;const int16_t *in;void *work;unsigned n,in_cap,out_cap,state_cap,work_cap;} Resample;
int op_silk_up2(Up2 *);
int op_silk_ar2(Ar2 *);
int op_silk_resampler_init(ResampleInit *);
int op_silk_resampler(Resample *);
typedef char resampler_size[(sizeof(silk_resampler_state_struct)==304&&offsetof(silk_resampler_state_struct,resampler_function)==264&&offsetof(silk_resampler_state_struct,Coefs)==296)?1:-1];
static uint32_t sr_rng=0xf941cb36;
static uint32_t sr_next(void){sr_rng^=sr_rng<<13;sr_rng^=sr_rng>>17;sr_rng^=sr_rng<<5;return sr_rng;}
static unsigned sr_up_checks,sr_ar_checks,sr_init_checks,sr_frames,sr_connected,sr_guards,sr_up_fir_frames;
static unsigned long long sr_samples,sr_history;
typedef struct {uint64_t before;silk_resampler_state_struct value;uint64_t after;} ResampleGuard;
typedef struct {uint64_t before;unsigned char value[736];uint64_t after;} ResampleWork;
static int sr_description(const silk_resampler_state_struct *a,const silk_resampler_state_struct *b){
 if(memcmp((const unsigned char *)a+264,(const unsigned char *)b+264,32))return 0;
 if(!a->Coefs||!b->Coefs)return a->Coefs==b->Coefs;
 int count=2+a->FIR_Order/2*a->FIR_Fracs;
 return !memcmp(a->Coefs,b->Coefs,count*2);
}
static int sr_state_equal(const silk_resampler_state_struct *a,const silk_resampler_state_struct *b){
 if(memcmp(a->sIIR,b->sIIR,sizeof(a->sIIR))||memcmp(a->delayBuf,b->delayBuf,sizeof(a->delayBuf))||!sr_description(a,b))return 0;
 if(memcmp(a->sFIR,b->sFIR,sizeof(a->sFIR)))return 0;
 return 1;
}
static int sr_init(silk_resampler_state_struct *a,silk_resampler_state_struct *b,int in,int out){
 memset(a,0xa5,sizeof(*a));ResampleGuard guard;memset(&guard,0xa5,sizeof(guard));guard.before=0x13579bdf98765432ULL;guard.after=0x2468ace012345678ULL;
 ResampleInit r={&guard.value,in,out,304},saved=r;
 if(silk_resampler_init(a,in,out,0)||!op_silk_resampler_init(&r)||memcmp(&r,&saved,sizeof(r))||memcmp(a,&guard.value,296)||!sr_description(a,&guard.value)||guard.before!=0x13579bdf98765432ULL||guard.after!=0x2468ace012345678ULL){printf("Init rate=%d/%d\n",in,out);return 0;}
 *b=guard.value;sr_init_checks++;return 1;
}
static int sr_frame(silk_resampler_state_struct *a,silk_resampler_state_struct *b,const int16_t *in,int n){
 int count=n*b->Fs_out_kHz/b->Fs_in_kHz;int16_t x[2882],y[2882],z[2882],saved_in[960];for(int i=0;i<2882;i++)x[i]=y[i]=z[i]=-12345;
 memcpy(saved_in,in,n*2);silk_resampler_state_struct saved_a=*a,saved_b=*b;
 ResampleGuard guard,second;guard.before=second.before=0x13579bdf98765432ULL;guard.after=second.after=0x2468ace012345678ULL;guard.value=second.value=*b;
 ResampleWork work,other;memset(&work,0xa5,sizeof(work));memset(&other,0x71,sizeof(other));work.before=other.before=guard.before;work.after=other.after=guard.after;
 Resample r={&guard.value,y+1,in,work.value,n,n,count,304,736},saved=r;
 Resample s={&second.value,z+1,in,other.value,n,n,count,304,736},saved_second=s;
 if(silk_resampler(a,x+1,in,n)||op_silk_resampler(&r)!=count||op_silk_resampler(&s)!=count||memcmp(x,y,sizeof(x))||memcmp(y,z,sizeof(y))||!sr_state_equal(a,&guard.value)||memcmp(&guard.value,&second.value,sizeof(guard.value))||memcmp(in,saved_in,n*2)||memcmp(&r,&saved,sizeof(r))||memcmp(&s,&saved_second,sizeof(s))||guard.before!=0x13579bdf98765432ULL||guard.after!=0x2468ace012345678ULL||second.before!=guard.before||second.after!=guard.after||work.before!=guard.before||work.after!=guard.after||other.before!=guard.before||other.after!=guard.after){
  printf("Resample frame=%u rate=%d/%d n=%d method=%d\n",sr_frames,b->Fs_in_kHz,b->Fs_out_kHz,n,b->resampler_function);
  for(int i=0;i<count;i++)if(x[i+1]!=y[i+1]){printf("PCM%d %d/%d\n",i,x[i+1],y[i+1]);break;}
  for(int i=0;i<6;i++)if(a->sIIR[i]!=guard.value.sIIR[i])printf("IIR%d %d/%d\n",i,a->sIIR[i],guard.value.sIIR[i]);
  for(int i=0;i<36;i++)if(a->sFIR[i]!=guard.value.sFIR[i]){printf("FIR%d %d/%d\n",i,a->sFIR[i],guard.value.sFIR[i]);break;}
  return 0;
 }
 if(b->resampler_function==2){
  if(memcmp(guard.value.sFIR+4,saved_b.sFIR+4,32*4)){puts("Unused ASM up-FIR state changed");return 0;}
  sr_up_fir_frames++;
 }
 (void)saved_a;*b=guard.value;sr_frames++;sr_samples+=count;sr_history+=6+48+36;return 1;
}
static int sr_raw(void){
 for(unsigned trial=0;trial<8192;trial++){
  unsigned n=trial%8==0?0:trial%8==1?960:trial%8==2?1:sr_next()%961;
  int32_t a[8],b[8];int16_t x[1922],y[1922],in[960],saved_in[960];
  for(int i=0;i<8;i++)a[i]=b[i]=(int32_t)(trial%8==0?0:trial%8==1?INT32_MAX:trial%8==2?INT32_MIN:sr_next());
  for(int i=0;i<960;i++)in[i]=(int16_t)(trial%8==0?0:trial%8==1?32767:trial%8==2?-32768:sr_next());
  memcpy(saved_in,in,sizeof(in));for(int i=0;i<1922;i++)x[i]=y[i]=-12345;
  silk_resampler_private_up2_HQ(a+1,x+1,in,n);Up2 r={b+1,y+1,in,n,6,n*2,n},saved=r;
  if(!op_silk_up2(&r)||memcmp(a,b,sizeof(a))||memcmp(x,y,sizeof(x))||memcmp(in,saved_in,sizeof(in))||memcmp(&r,&saved,sizeof(r))){printf("Raw up2 trial=%u n=%u\n",trial,n);return 0;}
  sr_up_checks++;sr_samples+=n*2;
 }
 for(unsigned trial=0;trial<8192;trial++){
  unsigned n=trial%8==0?0:trial%8==1?480:trial%8==2?1:sr_next()%481;
  int32_t a[4],b[4],x[482],y[482];int16_t in[480],saved_in[480],coef[2],saved_coef[2];
  for(int i=0;i<4;i++)a[i]=b[i]=(int32_t)sr_next();for(int i=0;i<482;i++)x[i]=y[i]=0x13579bdf;
  for(int i=0;i<480;i++)in[i]=(int16_t)sr_next();coef[0]=(int16_t)sr_next();coef[1]=(int16_t)sr_next();memcpy(saved_in,in,sizeof(in));memcpy(saved_coef,coef,sizeof(coef));
  silk_resampler_private_AR2(a+1,x+1,in,coef,n);Ar2 r={b+1,y+1,in,coef,n,2,n,n,2},saved=r;
  if(!op_silk_ar2(&r)||memcmp(a,b,sizeof(a))||memcmp(x,y,sizeof(x))||memcmp(in,saved_in,sizeof(in))||memcmp(coef,saved_coef,sizeof(coef))||memcmp(&r,&saved,sizeof(r))){printf("Raw AR2 trial=%u n=%u\n",trial,n);return 0;}
  sr_ar_checks++;sr_samples+=n;
 }
 return 1;
}
static int sr_streaming(void){
 const int inputs[]={8000,12000,16000},outputs[]={8000,12000,16000,24000,48000};
 for(int i=0;i<3;i++)for(int o=0;o<5;o++)for(int ms=1;ms<=60;ms++)for(unsigned pattern=0;pattern<8;pattern++){
  silk_resampler_state_struct a,b;if(!sr_init(&a,&b,inputs[i],outputs[o]))return 0;
  if(pattern>=6){
   for(int k=0;k<6;k++)a.sIIR[k]=b.sIIR[k]=(int32_t)sr_next();
   for(int k=0;k<36;k++)a.sFIR[k]=b.sFIR[k]=(int32_t)sr_next();
   for(int k=0;k<48;k++)a.delayBuf[k]=b.delayBuf[k]=(int16_t)sr_next();
  }
  for(unsigned frame=0;frame<4;frame++){
   int n=(frame==0?ms:frame==1?1:frame==2?60:1+sr_next()%60)*b.Fs_in_kHz;int16_t in[960];
   for(int k=0;k<n;k++)in[k]=(int16_t)(pattern==0?0:pattern==1?(k==0?32767:0):pattern==2?32767:pattern==3?-32768:pattern==4?(k%2?32767:-32768):pattern==5?(k*101+frame*127)%65536-32768:sr_next());
   if(!sr_frame(&a,&b,in,n))return 0;
  }
 }
 return 1;
}
static int sr_core_connected(void){
 const int inputs[]={8,12,16},outputs[]={8000,12000,16000,24000,48000};
 for(int r=0;r<3;r++)for(int o=0;o<5;o++)for(int subfr=2;subfr<=4;subfr+=2)for(unsigned trial=0;trial<32;trial++){
  int fs=inputs[r],order=fs==16?16:10,n=fs*subfr*5;Core core;ParamState param;silk_decoder_control ctrl;init(&core,&param,&ctrl,fs,trial);
  silk_resampler_state_struct a,b;if(!sr_init(&a,&b,fs*1000,outputs[o]))return 0;
  for(int frame=0;frame<4;frame++){
   SideInfoIndices ind;memset(&ind,0xa5,sizeof(ind));int cond=(trial+frame)%3;
   ind.signalType=(int8_t)((trial+frame)%3);ind.quantOffsetType=(int8_t)((trial+frame)%2);ind.Seed=(int8_t)((trial+frame)%4);ind.NLSFInterpCoef_Q2=(int8_t)((trial+frame)%5);
   ind.NLSFIndices[0]=(int8_t)(sr_next()%32);for(int j=1;j<=order;j++)ind.NLSFIndices[j]=(int8_t)((int)(sr_next()%7)-3);
   for(int j=0;j<subfr;j++)ind.GainsIndices[j]=(int8_t)(sr_next()%(j==0&&cond!=2?64:41));
   ind.PERIndex=(int8_t)(sr_next()%3);ind.LTP_scaleIndex=(int8_t)(sr_next()%3);ind.lagIndex=(int16_t)(sr_next()%(fs*16+1));ind.contourIndex=(int8_t)(sr_next()%(fs==8?(subfr==2?3:11):(subfr==2?12:34)));
   for(int j=0;j<subfr;j++)ind.LTPIndex[j]=(int8_t)(sr_next()%(8<<ind.PERIndex));param.first=frame==0;param.loss=0;
   if(!parameters(&ind,&param,&ctrl,fs,subfr,cond))continue;
   int pulses[320];for(int j=0;j<320;j++)pulses[j]=j<n?(int)(sr_next()%33)-16:0x13579bdf;
   if(!core_frame(&core,&ctrl,&ind,pulses,fs,subfr)||!sr_frame(&a,&b,core.out+fs*20-n,n))return 0;sr_connected++;
  }
 }
 return 1;
}
static int sr_invalid(void){
 silk_resampler_state_struct state,ref;if(!sr_init(&ref,&state,16000,48000))return 0;
 ResampleInit good={&state,16000,48000,304};
 for(unsigned k=0;k<7;k++){
  ResampleInit r=good;if(k==0)r.state=NULL;if(k==1)r.in=24000;if(k==2)r.out=44100;if(k==3)r.cap=303;if(k==4)r.in=0;if(k==5)r.out=0;if(k==6)r.in=-1;
  ResampleInit saved=r;silk_resampler_state_struct prior=state;if(op_silk_resampler_init(&r)||memcmp(&state,&prior,sizeof(state))||memcmp(&r,&saved,sizeof(r)))return 0;sr_guards++;
 }
 int16_t in[960]={0},out[2880];unsigned char work[736];memset(out,0xa5,sizeof(out));memset(work,0xa5,sizeof(work));
 Resample base={&state,out,in,work,320,320,960,304,736};
 for(unsigned k=0;k<26;k++){
  Resample r=base;silk_resampler_state_struct original=state;
  switch(k){case 0:r.state=NULL;break;case 1:r.out=NULL;break;case 2:r.in=NULL;break;case 3:r.work=NULL;break;case 4:r.n=0;break;case 5:r.n=15;break;case 6:r.n=321;break;case 7:r.n=976;r.in_cap=976;break;case 8:r.in_cap=319;break;case 9:r.out_cap=959;break;case 10:r.state_cap=303;break;case 11:r.work_cap=735;break;case 12:state.resampler_function=0;break;case 13:state.batchSize=159;break;case 14:state.invRatio_Q16++;break;case 15:state.FIR_Order=18;break;case 16:state.FIR_Fracs=3;break;case 17:state.Fs_in_kHz=24;break;case 18:state.Fs_out_kHz=44;break;case 19:state.inputDelay=17;break;case 20:state.Coefs=(const int16_t *)(uintptr_t)1;break;case 21:state.Fs_in_kHz=-1;break;case 22:state.Fs_out_kHz=0;break;case 23:state.resampler_function=INT32_MAX;break;case 24:state.invRatio_Q16=0;break;case 25:r.n=UINT32_MAX;r.in_cap=UINT32_MAX;break;}
  Resample saved=r;silk_resampler_state_struct prior=state;int16_t prior_out[2880];unsigned char prior_work[736];memcpy(prior_out,out,sizeof(out));memcpy(prior_work,work,sizeof(work));
  if(op_silk_resampler(&r)||memcmp(&r,&saved,sizeof(r))||memcmp(&state,&prior,sizeof(state))||memcmp(out,prior_out,sizeof(out))||memcmp(work,prior_work,sizeof(work))){printf("Resampler guard %u\n",k);return 0;}
  state=original;sr_guards++;
 }
 int32_t siir[6]={0},arout[480];int16_t upout[1920],coef[2]={0};memset(upout,0xa5,sizeof(upout));memset(arout,0xa5,sizeof(arout));
 Up2 ug={siir,upout,in,960,6,1920,960};
 for(unsigned k=0;k<7;k++){
  Up2 r=ug;if(k==0)r.state=NULL;if(k==1)r.out=NULL;if(k==2)r.in=NULL;if(k==3)r.n=961;if(k==4)r.state_cap=5;if(k==5)r.out_cap=1919;if(k==6)r.in_cap=959;
  Up2 saved=r;int16_t old_out[1920];memcpy(old_out,upout,sizeof(upout));if(op_silk_up2(&r)||memcmp(&r,&saved,sizeof(r))||memcmp(upout,old_out,sizeof(upout))||siir[0]||siir[1]||siir[2]||siir[3]||siir[4]||siir[5])return 0;sr_guards++;
 }
 Ar2 ag={siir,arout,in,coef,480,2,480,480,2};
 for(unsigned k=0;k<9;k++){
  Ar2 r=ag;if(k==0)r.state=NULL;if(k==1)r.out=NULL;if(k==2)r.in=NULL;if(k==3)r.coef=NULL;if(k==4)r.n=481;if(k==5)r.state_cap=1;if(k==6)r.out_cap=479;if(k==7)r.in_cap=479;if(k==8)r.coef_cap=1;
  Ar2 saved=r;int32_t old_out[480];memcpy(old_out,arout,sizeof(arout));if(op_silk_ar2(&r)||memcmp(&r,&saved,sizeof(r))||memcmp(arout,old_out,sizeof(arout))||siir[0]||siir[1])return 0;sr_guards++;
 }
 if(op_silk_resampler_init(NULL)||op_silk_resampler(NULL)||op_silk_up2(NULL)||op_silk_ar2(NULL))return 0;sr_guards+=4;return 1;
}
int main(void){
 if(!sr_raw()){puts("Raw resampling failed");return 1;}
 if(!sr_streaming()){puts("Streaming resampling failed");return 1;}
 if(!sr_core_connected()){puts("Connected core resampling failed");return 1;}
 if(!sr_invalid()){puts("Resampling guards failed");return 1;}
 printf("SILK resampler: %u exact raw up2 and %u AR2 filters, %u initializations across 15 rate pairs, %u PCM/history frames (%u connected core synthesis, %u fractional upsampling), %llu integer samples, %llu defined history values, %u guards; full RFC8251 up-FIR history checked and ASM tail preserved deterministically\n",sr_up_checks,sr_ar_checks,sr_init_checks,sr_frames,sr_connected,sr_up_fir_frames,sr_samples,sr_history,sr_guards);
 return 0;
}
