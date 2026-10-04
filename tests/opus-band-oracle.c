/* Test-only comparison with the hash-verified RFC6716 BSD decoder. */
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <math.h>
#include "modes.c"
#include "bands.c"
#include "rate.c"
#include "quant_bands.h"
typedef struct {
 ec_dec *ec;float *x,*y,*low,*out;int *remaining;uint32_t *seed;float *scratch;
 int n,budget,band,lm,spread,blocks,intensity,tf,level,fill;float gain;unsigned mask;
} Band;
int op_celt_band(Band *);
typedef struct {
 ec_dec *ec;float *x,*y;unsigned char *masks;int *pulses,*tf;float *norm,*scratch;uint32_t *seed;
 int start,end,lm,short_blocks,spread,dual,intensity,total,balance,coded,remaining_out,balance_out;
 unsigned x_cap,y_cap,norm_cap,scratch_cap,mask_cap;
} Bands;
int op_celt_bands(Bands *);
#include "celt-bands-reference.inc"
typedef struct {
 ec_dec *ec;float *old;int *tf,*offsets,*caps,*bits,*fine,*priority;
 int start,end,channels,lm,silence,transient,intra,spread,pitch;float gain;
 int tapset,trim,anti,balance,intensity,dual,coded,budget;
} Controls;
int op_celt_controls(Controls *);
#include "celt-controls-reference.inc"
static uint32_t random_state=0x125a8743;
static uint32_t next(void){random_state^=random_state<<13;random_state^=random_state>>17;random_state^=random_state<<5;return random_state;}
static unsigned vectors,guards,coefficients,frames,prefix_frames,real_frames;
static float max_error;
static int compare(const float *a,const float *b,int n,float tolerance){
 for(int i=0;i<n;i++){
  float error=fabsf(a[i]-b[i]);if(error>max_error)max_error=error;coefficients++;
  if(!isfinite(a[i])||!isfinite(b[i])||error>tolerance){printf("sample %d %.9g / %.9g error %.9g\n",i,a[i],b[i],error);return 0;}
 }return 1;
}
static int trial(unsigned char *data,unsigned len,int band,int lm,int budget,int remaining,int spread,int blocks,int stereo,int intensity,int tf,int fill,int fold,float gain,unsigned prime){
 const CELTMode *m=&mode48000_960_120;
 int n=(m->eBands[band+1]-m->eBands[band])<<lm;
 float xa[178],xb[178],ya[178],yb[178],oa[178],ob[178],la[178],lb[178],sa[178],sb[178];
 for(int i=0;i<178;i++){
  xa[i]=xb[i]=ya[i]=yb[i]=oa[i]=ob[i]=sa[i]=sb[i]=123456.0f;
  la[i]=lb[i]=((int)(next()%2001)-1000)*.003f;
 }
 ec_dec a,b;memset(&a,0,sizeof(a));memset(&b,0,sizeof(b));ec_dec_init(&a,data,len);ec_dec_init(&b,data,len);
 for(unsigned i=0;i<prime;i++){unsigned logp=1+next()%15;ec_dec_bit_logp(&a,logp);ec_dec_bit_logp(&b,logp);}
 int ra=remaining,rb=remaining;uint32_t seeda=next(),seedb=seeda;
 unsigned mask=quant_band(0,m,band,xa+1,stereo?ya+1:NULL,n,budget,spread,blocks,intensity,tf,fold?la+1:NULL,&a,&ra,lm,oa+1,NULL,0,&seeda,gain,sa+1,fill);
 struct {uint64_t before;Band request;uint64_t after;} guarded={0};
 guarded.before=0xabcd987601234567ULL;guarded.after=0x765432109876dcbaULL;
 Band args={&b,xb+1,stereo?yb+1:NULL,fold?lb+1:NULL,ob+1,&rb,&seedb,sb+1,n,budget,band,lm,spread,blocks,intensity,tf,0,fill,gain,0xdeadbeef};
 guarded.request=args;
 int ok=op_celt_band(&guarded.request);
 if(!ok||mask!=guarded.request.mask||ra!=rb||seeda!=seedb||memcmp(&a,&b,sizeof(a))||
    guarded.before!=0xabcd987601234567ULL||guarded.after!=0x765432109876dcbaULL||memcmp(&guarded.request,&args,offsetof(Band,mask))||
    xb[0]!=123456.0f||xb[n+1]!=123456.0f||yb[0]!=123456.0f||yb[n+1]!=123456.0f||ob[0]!=123456.0f||ob[n+1]!=123456.0f||sb[0]!=123456.0f||sb[n+1]!=123456.0f||
    memcmp(la,lb,sizeof(la))||!compare(xa+1,xb+1,n,.00001f)||!compare(oa+1,ob+1,n,.00004f)||(stereo&&!compare(ya+1,yb+1,n,.00001f))){
  printf("Band mismatch ok=%d band=%d LM=%d N=%d b=%d rem=%d/%d spread=%d B=%d stereo=%d intensity=%d tf=%d fill=%x fold=%d gain=%g len=%u mask=%x/%x seed=%x/%x tell=%d/%d\n",ok,band,lm,n,budget,ra,rb,spread,blocks,stereo,intensity,tf,fill,fold,gain,len,mask,guarded.request.mask,seeda,seedb,ec_tell_frac(&a),ec_tell_frac(&b));return 0;
 }
 vectors++;return 1;
}
static int invalid(void){
 unsigned char data[16]={0};ec_dec ec;memset(&ec,0,sizeof(ec));ec_dec_init(&ec,data,16);
 float x[176],y[176],low[176],out[176],scratch[176],backup[176];for(int i=0;i<176;i++)x[i]=y[i]=low[i]=out[i]=scratch[i]=backup[i]=1.0f;
 int remaining=2000;uint32_t seed=128;
 Band good={&ec,x,y,low,out,&remaining,&seed,scratch,8,128,8,2,2,4,21,0,0,15,1.f,0xdeadbeef};
 for(unsigned test=0;test<38;test++){
  Band request=good,copy;ec_dec original=ec,saved;
  switch(test){case 0:request.ec=NULL;break;case 1:request.x=NULL;break;case 2:request.remaining=NULL;break;case 3:request.seed=NULL;break;
   case 4:request.n=0;break;case 5:request.n=9;break;case 6:request.budget=-1;break;case 7:request.budget=16384;break;
   case 8:request.band=-1;break;case 9:request.band=21;break;case 10:request.lm=-1;break;case 11:request.lm=4;break;
   case 12:request.spread=-1;break;case 13:request.spread=4;break;case 14:request.blocks=0;break;case 15:request.blocks=3;break;case 16:request.blocks=8;break;
   case 17:request.intensity=-1;break;case 18:request.intensity=22;break;case 19:request.tf=-4;break;case 20:request.tf=4;break;case 21:request.tf=3;break;
   case 22:request.level=1;break;case 23:request.fill=16;break;case 24:request.gain=NAN;break;case 25:request.gain=-.1f;break;case 26:request.gain=1.001f;break;
   case 27:request.scratch=NULL;break;case 28:ec.storage=1276;break;case 29:ec.buf=NULL;break;case 30:ec.offs=17;break;case 31:ec.end_offs=17;break;
   case 32:ec.rng=0;break;case 33:ec.nend_bits=33;break;case 34:ec.nbits_total=32769;break;case 35:remaining=81601;break;case 36:low[7]=NAN;break;case 37:low[7]=32.001f;break;
  }
  copy=request;saved=ec;int saved_remaining=remaining;float saved_low=low[7];
  if(op_celt_band(&request)||memcmp(&request,&copy,sizeof(copy))||memcmp(&ec,&saved,sizeof(ec))||remaining!=saved_remaining||seed!=128||memcmp(x,backup,sizeof(x))||memcmp(y,backup,sizeof(y))||memcmp(out,backup,sizeof(out))||memcmp(scratch,backup,sizeof(scratch))||memcmp(&low[7],&saved_low,4)){printf("Invalid guard %u failed\n",test);return 0;}
  ec=original;remaining=2000;low[7]=1.0f;guards++;
 }
 if(op_celt_band(NULL))return 0;guards++;return 1;
}
static int frame(ec_dec *a,ec_dec *b,int C,int lm,int start,int end,int short_blocks,int spread,int dual,int intensity,int total,int balance,int coded,int *pulses,int *tf){
 const unsigned size=100U<<lm,norm_size=size*C,scratch_size=22U<<lm;
 float xa[802],xb[802],ya[802],yb[802],na[1602],nb[1602],sa[178],sb[178];unsigned char ma[44],mb[44];
 for(int i=0;i<802;i++)xa[i]=xb[i]=ya[i]=yb[i]=123456.f;
 for(int i=0;i<1602;i++)na[i]=nb[i]=123456.f;
 for(int i=0;i<178;i++)sa[i]=sb[i]=123456.f;
 memset(ma,0xa5,sizeof(ma));memset(mb,0xa5,sizeof(mb));
 uint32_t seeda=next(),seedb=seeda;
 Bands x={a,xa+1,C==2?ya+1:NULL,ma+1,pulses,tf,na+1,sa+1,&seeda,start,end,lm,short_blocks,spread,dual,intensity,total,balance,coded,0,0,size,size,norm_size,scratch_size,21U*C};
 Bands y=x;y.ec=b;y.x=xb+1;y.y=C==2?yb+1:NULL;y.masks=mb+1;y.norm=nb+1;y.scratch=sb+1;y.seed=&seedb;
 Bands saved=y;
 reference_bands(&x);
 int ok=op_celt_bands(&y);
 if(!ok||memcmp(a,b,sizeof(*a))||seeda!=seedb||x.remaining_out!=y.remaining_out||x.balance_out!=y.balance_out||memcmp(ma,mb,sizeof(ma))||
   memcmp(&saved,&y,offsetof(Bands,remaining_out))||memcmp((char*)&saved+120,(char*)&y+120,24)||
   xb[0]!=123456.f||xb[size+1]!=123456.f||yb[0]!=123456.f||yb[size+1]!=123456.f||nb[0]!=123456.f||nb[norm_size+1]!=123456.f||sb[0]!=123456.f||sb[scratch_size+1]!=123456.f||
   !compare(xa+1,xb+1,size,.00001f)||(C==2&&!compare(ya+1,yb+1,size,.00001f))||!compare(na+1,nb+1,norm_size,.00004f)){
  printf("Full-band mismatch ok=%d C=%d LM=%d start/end=%d/%d short=%d spread=%d dual=%d intensity=%d total=%d balance=%d/%d remaining=%d/%d tell=%d/%d seed=%x/%x coded=%d\n",ok,C,lm,start,end,short_blocks,spread,dual,intensity,total,x.balance_out,y.balance_out,x.remaining_out,y.remaining_out,ec_tell_frac(a),ec_tell_frac(b),seeda,seedb,coded);return 0;
 }
 frames++;return 1;
}
static int prefix_frame(const unsigned char *payload,unsigned len,int C,int LM,int start,int end){
 ec_dec a,b;memset(&a,0,sizeof(a));memset(&b,0,sizeof(b));ec_dec_init(&a,(unsigned char*)payload,len);ec_dec_init(&b,(unsigned char*)payload,len);
 float ea[42],eb[42];for(int i=0;i<42;i++)ea[i]=eb[i]=-28.f;
 int ar[6][21]={{0}},br[6][21]={{0}};
 Controls x={&a,ea,ar[0],ar[1],ar[2],ar[3],ar[4],ar[5],start,end,C,LM};
 Controls y={&b,eb,br[0],br[1],br[2],br[3],br[4],br[5],start,end,C,LM};
 if(reference_controls(&x)!=op_celt_controls(&y)||memcmp(&a,&b,sizeof(a))||memcmp(ea,eb,sizeof(ea))||memcmp(ar,br,sizeof(ar))||memcmp((char*)&x+80,(char*)&y+80,56)){puts("Connected prefix mismatch");return 0;}
 if(!frame(&a,&b,C,LM,start,end,x.transient,x.spread,x.dual,x.intensity,(int)len*64-x.anti,x.balance,x.coded,x.bits,x.tf))return 0;
 prefix_frames++;return 1;
}
static int all_invalid(void){
 unsigned char payload[16]={0},masks[42],saved_masks[42];ec_dec ec;memset(&ec,0,sizeof(ec));ec_dec_init(&ec,payload,16);
 float x[800],y[800],norm[1600],scratch[176],backup[800];int pulses[21]={0},tf[21]={0};uint32_t seed=128;
 for(int i=0;i<800;i++)x[i]=y[i]=backup[i]=1.f;for(int i=0;i<1600;i++)norm[i]=1.f;for(int i=0;i<176;i++)scratch[i]=1.f;
 memset(masks,123,sizeof(masks));memcpy(saved_masks,masks,sizeof(masks));
 Bands good={&ec,x,y,masks,pulses,tf,norm,scratch,&seed,0,21,3,1,2,1,15,1024,128,21,0,0,800,800,1600,176,42};
 for(unsigned test=0;test<40;test++){
  Bands request=good,saved;ec_dec original=ec,saved_ec;
  if(test<9&&test!=2)((void**)&request)[test]=NULL;
  else switch(test){case 2:request.y=NULL;break;case 9:request.start=-1;break;case 10:request.end=22;break;case 11:request.end=0;break;
   case 12:request.lm=4;break;case 13:request.short_blocks=2;break;case 14:request.spread=4;break;case 15:request.dual=2;break;
   case 16:request.intensity=22;break;case 17:request.total=81601;break;case 18:request.balance=-81601;break;case 19:request.balance=81601;break;
   case 20:request.coded=-1;break;case 21:request.coded=22;break;case 22:request.x_cap=799;break;case 23:request.y_cap=799;break;
   case 24:request.norm_cap=1599;break;case 25:request.scratch_cap=175;break;case 26:request.mask_cap=41;break;
   case 27:pulses[20]=-1;break;case 28:tf[20]=4;break;case 29:tf[20]=-4;break;case 30:request.short_blocks=0;tf[20]=1;break;
   case 31:ec.storage=1276;break;case 32:ec.buf=NULL;break;case 33:ec.offs=17;break;case 34:ec.end_offs=17;break;
   case 35:ec.rng=0;break;case 36:ec.nend_bits=33;break;case 37:ec.nbits_total=32769;break;case 38:request.start=22;break;case 39:request.lm=-1;break;
  }
  saved=request;saved_ec=ec;
  if(op_celt_bands(&request)||memcmp(&request,&saved,sizeof(saved))||memcmp(&ec,&saved_ec,sizeof(ec))||seed!=128||memcmp(x,backup,sizeof(x))||memcmp(y,backup,sizeof(y))||memcmp(masks,saved_masks,sizeof(masks))){printf("Full-band guard %u failed\n",test);return 0;}
  for(int i=0;i<1600;i++)if(norm[i]!=1.f)return 0;for(int i=0;i<176;i++)if(scratch[i]!=1.f)return 0;
  ec=original;pulses[20]=0;tf[20]=0;guards++;
 }
 if(op_celt_bands(NULL))return 0;guards++;return 1;
}
/* Real committed CELT packets, with connected flags, energy and allocation. */
static int fixture(const char *filename){
 FILE *f=fopen(filename,"rb");if(!f)return 0;
 unsigned char data[8192],packet[4096];size_t len=fread(data,1,sizeof(data),f),at=0,packet_len=0;fclose(f);
 while(at<len){
  if(len-at<27||memcmp(data+at,"OggS",4))return 0;
  unsigned segments=data[at+26];if(len-at<27+segments)return 0;size_t body=at+27+segments;
  for(unsigned i=0;i<segments;i++){
   unsigned count=data[at+27+i];if(body+count>len||packet_len+count>sizeof(packet))return 0;
   memcpy(packet+packet_len,data+body,count);packet_len+=count;body+=count;
   if(count<255){
    if(packet_len&&(packet[0]&0x80)&&memcmp(packet,"OpusHead",packet_len<8?packet_len:8)&&memcmp(packet,"OpusTags",packet_len<8?packet_len:8)){
     const unsigned char *parts[48];opus_int16 sizes[48];unsigned char toc;
     int count_frames=opus_packet_parse(packet,(opus_int32)packet_len,&toc,parts,sizes,NULL);if(count_frames<1)return 0;
     int end=13+2*((toc>>5)&3);if(end==15)end=17;else if(end==17)end=19;else if(end==19)end=21;
     for(int k=0;k<count_frames;k++){if(!prefix_frame(parts[k],sizes[k],1+((toc>>2)&1),(toc>>3)&3,0,end))return 0;real_frames++;}
    }
    packet_len=0;
   }
  }at=body;
 }return packet_len==0&&real_frames>0;
}
int main(int argc,char **argv){
 if(sizeof(Band)!=112||offsetof(Band,n)!=64||offsetof(Band,mask)!=108)return 2;
 if(sizeof(Bands)!=144||offsetof(Bands,remaining_out)!=112)return 2;
 if(!invalid()||!all_invalid())return 1;
 const unsigned lengths[]={0,1,2,4,16,128,1275};
 const int budgets[]={0,1,8,16,24,32,64,128,256,512,1024,16383};
 unsigned char payload[1275];
 for(unsigned kind=0;kind<3;kind++)for(unsigned l=0;l<sizeof(lengths)/sizeof(lengths[0]);l++){
  unsigned len=lengths[l];for(unsigned i=0;i<len;i++)payload[i]=kind==0?0:kind==1?255:(unsigned char)next();
  for(int lm=0;lm<4;lm++)for(int band=0;band<21;band++)for(unsigned q=0;q<sizeof(budgets)/sizeof(budgets[0]);q++)for(int stereo=0;stereo<2;stereo++){
   int B=(q&1)?1<<lm:1,tf=(q%3)==0?-1:(q%3)==1&&B>1?1:0;
   if(!trial(payload,len,band,lm,budgets[q],q==0?-17:q==1?0:q==2?8:81600,q%4,B,stereo,(q&1)?21:0,tf,(q%5)?(1<<B)-1:0,q&1,(q%3)?1.f:.25f,q%4))return 1;
  }
 }
 for(unsigned t=0;t<32768;t++){
  unsigned len=next()%1276;for(unsigned i=0;i<len;i++)payload[i]=(unsigned char)next();
  int lm=next()%4,band=next()%21,B=(next()&1)?1<<lm:1;
  int tf=(int)(next()%(lm+4))-3;if(tf>0&&B==1)tf=0;
  int n=(mode48000_960_120.eBands[band+1]-mode48000_960_120.eBands[band])<<lm;
  int nb=n/B,bt=B,tt=tf;while(tt<0&&!(nb&1)){nb>>=1;bt<<=1;tt++;}if(bt>16)tf=0;
  if(!trial(payload,len,band,lm,next()%16384,(int)(next()%81618)-17,next()%4,B,next()%2,next()%22,tf,next()%((1<<B)),next()%2,(next()%4096+1)/4096.f,next()%8))return 1;
 }
 for(unsigned t=0;t<16384;t++){
  unsigned len=next()%1276;for(unsigned i=0;i<len;i++)payload[i]=(unsigned char)next();
  int C=1+next()%2,lm=next()%4,start=next()%21,end=start+1+next()%(21-start),short_blocks=next()%2;
  int pulses[21]={0},tf[21]={0};
  for(int i=start;i<end;i++){pulses[i]=next()%4097;tf[i]=tf_select_table[lm][4*short_blocks+next()%4];}
  ec_dec a,b;memset(&a,0,sizeof(a));memset(&b,0,sizeof(b));ec_dec_init(&a,payload,len);ec_dec_init(&b,payload,len);
  for(unsigned j=0;j<t%8;j++){unsigned logp=1+next()%15;ec_dec_bit_logp(&a,logp);ec_dec_bit_logp(&b,logp);}
  if(!frame(&a,&b,C,lm,start,end,short_blocks,next()%4,C==2?next()%2:0,next()%22,len*64,(int)(next()%1025)-512,start+next()%(end-start+1),pulses,tf))return 1;
  if(t<8192&&!prefix_frame(payload,len,C,lm,start,end))return 1;
 }
 if(argc!=2||!fixture(argv[1])){puts("Committed spectral-frame fixture failed");return 1;}
 printf("Passed %u recursive band comparisons, %u full spectral frames (%u connected prefixes including %u real frames), %u coefficient checks and %u invalid guards; exact entropy/budget/seed; maximum float error %.9g.\n",vectors,frames,prefix_frames,real_frames,coefficients,guards,max_error);return 0;
}
