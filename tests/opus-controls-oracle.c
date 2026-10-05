/* Development-only comparison with the normative BSD RFC6716 frame prefix. */
#include "lamp-test.h"
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include "modes.c"
#include "rate.c"
#include "quant_bands.c"
#include "bands.h"
typedef struct {
 ec_dec *ec; float *old; int *tf,*offsets,*caps,*bits,*fine,*priority;
 int start,end,channels,lm;
 int silence,transient,intra,spread,pitch; float gain;
 int tapset,trim,anti,balance,intensity,dual,coded,budget;
} Controls;
LAMP_ABI int op_celt_tf_decode(Controls *);
LAMP_ABI int op_celt_controls(Controls *);
#include "celt-controls-reference.inc"
static uint32_t seed=0x91f07326;
static uint32_t next(void){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;}
static unsigned controls_checks,tf_checks,invalid_checks,real_checks;
typedef struct {uint32_t before; int values[21]; uint32_t after;} Band;
typedef struct {uint32_t before; float values[42]; uint32_t after;} Energy;
static void init_band(Band *b){b->before=0x13579bdf;b->after=0x2468ace0;for(int i=0;i<21;i++)b->values[i]=-1234567;}
static int guards(const Band *b){return b->before==0x13579bdf&&b->after==0x2468ace0;}
static int compare_prefix(const unsigned char *payload,unsigned len,int C,int LM,int start,int end,unsigned prime){
 ec_dec a,b;memset(&a,0,sizeof(a));memset(&b,0,sizeof(b));
 ec_dec_init(&a,(unsigned char*)payload,len);ec_dec_init(&b,(unsigned char*)payload,len);
 for(unsigned i=0;i<prime;i++){unsigned logp=1+next()%12;ec_dec_bit_logp(&a,logp);ec_dec_bit_logp(&b,logp);}
 Band ra[6],rb[6];for(unsigned i=0;i<6;i++){init_band(&ra[i]);init_band(&rb[i]);}
 Energy ea,eb;ea.before=eb.before=0x98765432;ea.after=eb.after=0x12345678;
 for(unsigned i=0;i<42;i++)ea.values[i]=eb.values[i]=((int)(next()%6001)-3000)*0.01f;
 Controls x={&a,ea.values,ra[0].values,ra[1].values,ra[2].values,ra[3].values,ra[4].values,ra[5].values,start,end,C,LM};
 Controls y={&b,eb.values,rb[0].values,rb[1].values,rb[2].values,rb[3].values,rb[4].values,rb[5].values,start,end,C,LM};
 int expected=reference_controls(&x),actual=op_celt_controls(&y);
 if(expected!=actual||memcmp((char*)&x+80,(char*)&y+80,56)||memcmp(&a,&b,sizeof(a))||memcmp(&ea,&eb,sizeof(ea))){
  printf("Prefix mismatch len=%u C=%d LM=%d start=%d end=%d prime=%u coded=%d/%d tell=%d/%d range=%u/%u\n",len,C,LM,start,end,prime,expected,actual,ec_tell(&a),ec_tell(&b),a.rng,b.rng);
  int *p=(int*)((char*)&x+80),*q=(int*)((char*)&y+80);for(int i=0;i<14;i++)if(p[i]!=q[i])printf("scalar %d: %d/%d\n",i,p[i],q[i]);
  for(int i=0;i<42;i++)if(ea.values[i]!=eb.values[i])printf("energy %d: %.9g/%.9g\n",i,ea.values[i],eb.values[i]);
  return 0;
 }
 if(ea.before!=0x98765432||ea.after!=0x12345678)return 0;
 for(unsigned i=0;i<6;i++)if(!guards(&ra[i])||!guards(&rb[i])||memcmp(&ra[i],&rb[i],sizeof(Band))){printf("Band array mismatch %u\n",i);return 0;}
 controls_checks++;return 1;
}
static int trial_tf(const unsigned char *payload,unsigned len,int LM,int transient,int start,int end,unsigned prime){
 ec_dec a,b;memset(&a,0,sizeof(a));memset(&b,0,sizeof(b));ec_dec_init(&a,(unsigned char*)payload,len);ec_dec_init(&b,(unsigned char*)payload,len);
 for(unsigned i=0;i<prime;i++){unsigned logp=1+next()%12;ec_dec_bit_logp(&a,logp);ec_dec_bit_logp(&b,logp);}
 Band x,y;init_band(&x);init_band(&y);
 tf_decode(start,end,transient,x.values,LM,&a);
 Controls request={0};request.ec=&b;request.tf=y.values;request.start=start;request.end=end;request.lm=LM;request.transient=transient;
 if(!op_celt_tf_decode(&request)||memcmp(&x,&y,sizeof(x))||memcmp(&a,&b,sizeof(a))||!guards(&y)){
  printf("TF mismatch len=%u LM=%d transient=%d start=%d end=%d prime=%u\n",len,LM,transient,start,end,prime);return 0;
 }
 tf_checks++;return 1;
}
static int invalid(void){
 unsigned char payload[16]={0};ec_dec ec;memset(&ec,0,sizeof(ec));ec_dec_init(&ec,payload,16);
 float old[42]={0};int arrays[6][21]={{0}};
 Controls good={&ec,old,arrays[0],arrays[1],arrays[2],arrays[3],arrays[4],arrays[5],0,21,2,3};
 for(unsigned test=0;test<24;test++){
  Controls request=good,copy;ec_dec saved,backup=ec;float oldcopy[42];int arraycopy[6][21];
  if(test<8)((void**)&request)[test]=NULL;
  else switch(test){
   case 8:request.start=-1;break;case 9:request.end=22;break;case 10:request.end=0;break;
   case 11:request.channels=0;break;case 12:request.channels=3;break;
   case 13:request.lm=-1;break;case 14:request.lm=4;break;
   case 15:ec.storage=1276;break;case 16:ec.buf=NULL;break;
   case 17:ec.offs=17;break;case 18:ec.end_offs=17;break;
   case 19:ec.rng=0;break;case 20:ec.nend_bits=33;break;case 21:ec.nbits_total=32769;break;
   case 22:{uint32_t nan=0x7fc00000;memcpy(old,&nan,4);break;}
   case 23:{uint32_t inf=0x7f800000;memcpy(old+41,&inf,4);break;}
  }
  copy=request;saved=ec;memcpy(oldcopy,old,sizeof(old));memcpy(arraycopy,arrays,sizeof(arrays));
  if(op_celt_controls(&request)!=-1||memcmp(&request,&copy,sizeof(copy))||memcmp(&ec,&saved,sizeof(ec))||memcmp(old,oldcopy,sizeof(old))||memcmp(arrays,arraycopy,sizeof(arrays)))return 0;
  ec=backup;memset(old,0,sizeof(old));invalid_checks++;
 }
 if(op_celt_controls(NULL)!=-1||op_celt_tf_decode(NULL)!=0)return 0;invalid_checks+=2;
 for(unsigned test=0;test<7;test++){
  Controls request=good,copy;ec_dec saved=ec;int arraycopy[6][21];
  switch(test){case 0:request.ec=NULL;break;case 1:request.tf=NULL;break;case 2:request.start=21;break;case 3:request.end=0;break;case 4:request.lm=4;break;case 5:request.transient=2;break;case 6:request.transient=-1;break;}
  copy=request;memcpy(arraycopy,arrays,sizeof(arrays));
  if(op_celt_tf_decode(&request)||memcmp(&request,&copy,sizeof(copy))||memcmp(&ec,&saved,sizeof(ec))||memcmp(arrays,arraycopy,sizeof(arrays)))return 0;
  invalid_checks++;
 }
 return 1;
}
/* Exercise actual CELT frames in the committed Ogg/Opus fixture. */
static int fixture(const char *filename){
 FILE *f=fopen(filename,"rb");if(!f)return 0;
 unsigned char data[8192],packet[4096];size_t len=fread(data,1,sizeof(data),f),at=0,packet_len=0;fclose(f);
 while(at<len){
  if(len-at<27||memcmp(data+at,"OggS",4))return 0;
  unsigned segments=data[at+26];if(len-at<27+segments)return 0;
  size_t body=at+27+segments;
  for(unsigned i=0;i<segments;i++){
   unsigned count=data[at+27+i];if(body+count>len||packet_len+count>sizeof(packet))return 0;
   memcpy(packet+packet_len,data+body,count);packet_len+=count;body+=count;
   if(count<255){
    if(packet_len>=1&&(packet[0]&0x80)&&memcmp(packet,"OpusHead",packet_len<8?packet_len:8)&&memcmp(packet,"OpusTags",packet_len<8?packet_len:8)){
     const unsigned char *frames[48];opus_int16 sizes[48];unsigned char toc;
     int n=opus_packet_parse(packet,(opus_int32)packet_len,&toc,frames,sizes,NULL);if(n<1)return 0;
     int end=13+2*((toc>>5)&3);if(end==15)end=17;else if(end==17)end=19;else if(end==19)end=21;
     for(int k=0;k<n;k++){if(!compare_prefix(frames[k],sizes[k],1+((toc>>2)&1),(toc>>3)&3,0,end,0))return 0;real_checks++;}
    }
    packet_len=0;
   }
  }
  at=body;
 }
 return packet_len==0&&real_checks>0;
}
int main(int argc,char **argv){
 if(sizeof(Controls)!=136||offsetof(Controls,silence)!=80)return 2;
 if(!invalid()){puts("Invalid request mutated output or entropy state");return 1;}
 unsigned char payload[1275];
 const unsigned lengths[]={0,1,2,3,4,5,6,8,12,16,32,64,128,256,511,1275};
 for(unsigned kind=0;kind<3;kind++)for(unsigned l=0;l<sizeof(lengths)/sizeof(lengths[0]);l++){
  unsigned len=lengths[l];for(unsigned i=0;i<len;i++)payload[i]=kind==0?0:kind==1?255:(unsigned char)next();
  for(int LM=0;LM<4;LM++)for(int C=1;C<=2;C++)for(int end=1;end<=21;end++){
   if(!compare_prefix(payload,len,C,LM,0,end,0))return 1;
   if(!compare_prefix(payload,len,C,LM,end-1,end,8))return 1;
  }
  for(int LM=0;LM<4;LM++)for(int transient=0;transient<2;transient++)for(int end=1;end<=21;end++){
   if(!trial_tf(payload,len,LM,transient,0,end,0)||!trial_tf(payload,len,LM,transient,end-1,end,8))return 1;
  }
 }
 for(unsigned trial=0;trial<32768;trial++){
  unsigned len=next()%1276;for(unsigned i=0;i<len;i++)payload[i]=(unsigned char)next();
  int start=next()%21,end=start+1+next()%(21-start);
  if(!compare_prefix(payload,len,1+next()%2,next()%4,start,end,next()%16))return 1;
  if(!trial_tf(payload,len,next()%4,next()%2,start,end,next()%16))return 1;
 }
 if(argc!=2||!fixture(argv[1])){puts("Committed Opus fixture prefix comparison failed");return 1;}
 printf("Passed %u CELT frame-prefix/entropy comparisons, %u TF/entropy comparisons, %u invalid-request guards, including %u real CELT frames.\n",controls_checks,tf_checks,invalid_checks,real_checks);
 return 0;
}
