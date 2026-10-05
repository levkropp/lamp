/* Test-only normative CELT PVQ reconstruction and spreading comparison. */
#include "lamp-test.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include "vq.c"
typedef struct{float *x;ec_dec *ec;int n,k,spread,blocks;float gain;unsigned mask;} Unquant;
LAMP_ABI int op_celt_unquant(Unquant *);
LAMP_ABI int op_celt_spread(float *,int,int,int,int,int);
LAMP_ABI int op_celt_renormalize(float *,int,float);
static uint32_t seed=0x75424819;
static uint32_t next(void){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;}
static unsigned vectors,rotations,guards,renorms;
static float max_error;
static int fits(int n,int k){
 static const int maxN[15]={32767,32767,32767,1476,283,109,60,40,29,24,20,18,16,14,13};
 static const int maxK[15]={32767,32767,32767,32767,1172,238,95,53,36,27,22,18,16,15,13};
 return n>=14?(k<14&&n<=maxN[k]):k<=maxK[n];
}
static int compare(const float *a,const float *b,int n,float tolerance){
 for(int i=0;i<n;i++){float e=fabsf(a[i]-b[i]);if(e>max_error)max_error=e;if(!isfinite(b[i])||e>tolerance){printf("sample %d %.9g / %.9g error %.9g\n",i,a[i],b[i],e);return 0;}}
 return 1;
}
static int pulse(int n,int k,int spread,int B,float gain){
 unsigned char payload[128];float x[1026],y[1026];ec_dec a,b;
 for(unsigned i=0;i<sizeof(payload);i++)payload[i]=(unsigned char)next();
 for(int i=0;i<1026;i++)x[i]=y[i]=123456.0f;
 memset(&a,0,sizeof(a));memset(&b,0,sizeof(b));ec_dec_init(&a,payload,sizeof(payload));ec_dec_init(&b,payload,sizeof(payload));
 for(int j=0;j<6;j++){unsigned logp=next()%15+1;ec_dec_bit_logp(&a,logp);ec_dec_bit_logp(&b,logp);}
 unsigned mask=alg_unquant(x+1,n,k,spread,B,&a,gain);
 Unquant request={y+1,&b,n,k,spread,B,gain,0xdeadbeef};
 if(!op_celt_unquant(&request)||mask!=request.mask||memcmp(&a,&b,sizeof(a))||
    y[0]!=123456.0f||y[n+1]!=123456.0f||!compare(x+1,y+1,n,0.000003f)){
  printf("PVQ mismatch N=%d K=%d spread=%d B=%d gain=%.9g masks=%u/%u\n",n,k,spread,B,gain,mask,request.mask);return 0;
 }
 double energy=0;for(int i=0;i<n;i++)energy+=(double)y[i+1]*y[i+1];
 if(fabs(energy-(double)gain*gain)>0.00002){printf("PVQ norm mismatch %.9g gain %.9g\n",energy,gain);return 0;}
 vectors++;return 1;
}
static int rotation(int n,int k,int spread,int B,int dir){
 float x[1026],y[1026];double before=0,after=0;
 for(int i=0;i<n;i++){x[i+1]=y[i+1]=((int)(next()%20001)-10000)*0.00002f;before+=(double)x[i+1]*x[i+1];}
 x[0]=y[0]=x[n+1]=y[n+1]=123456.0f;
 exp_rotation(x+1,n,dir,B,k,spread);
 if(!op_celt_spread(y+1,n,dir,B,k,spread)||y[0]!=123456.0f||y[n+1]!=123456.0f||!compare(x+1,y+1,n,0.000003f)){
  printf("Rotation mismatch N=%d K=%d spread=%d B=%d dir=%d\n",n,k,spread,B,dir);return 0;
 }
 for(int i=0;i<n;i++)after+=(double)y[i+1]*y[i+1];
 if(fabs(after-before)>0.00005*(1+before)){printf("Rotation norm mismatch %.9g/%.9g\n",before,after);return 0;}
 rotations++;return 1;
}
static int invalid(void){
 unsigned char bytes[16]={0};ec_dec a,saved;memset(&a,0,sizeof(a));ec_dec_init(&a,bytes,16);
 float output[1024],backup[1024];for(int i=0;i<1024;i++)output[i]=123.0f;
 Unquant good={output,&a,8,1,2,1,1.0f,0xdeadbeef};
 for(int i=0;i<15;i++){
  Unquant u=good,copy;
  switch(i){case 0:u.x=0;break;case 1:u.ec=0;break;case 2:u.n=1;break;case 3:u.n=1025;break;case 4:u.k=0;break;case 5:u.k=32768;break;case 6:u.spread=4;break;case 7:u.blocks=3;break;case 8:u.n=10;u.blocks=4;break;case 9:u.gain=NAN;break;case 10:u.gain=INFINITY;break;case 11:u.gain=-.1f;break;case 12:u.gain=1.01f;break;case 13:u.n=1024;u.k=14;break;case 14:u.n=13;u.k=16;break;}
  copy=u;saved=a;memcpy(backup,output,sizeof(output));
  if(op_celt_unquant(&u)||memcmp(&u,&copy,sizeof(u))||memcmp(&a,&saved,sizeof(a))||memcmp(output,backup,sizeof(output)))return 0;
  guards++;
 }
 if(op_celt_unquant(0))return 0;guards++;
 const int bad[][5]={{1,-1,1,1,1},{1025,-1,1,1,1},{8,0,1,1,1},{8,-1,3,1,1},{10,-1,4,1,1},{8,-1,1,-1,1},{8,-1,1,32768,1},{8,-1,1,1,4}};
 for(unsigned i=0;i<sizeof(bad)/sizeof(bad[0]);i++){
  memcpy(backup,output,sizeof(output));
  if(op_celt_spread(output,bad[i][0],bad[i][1],bad[i][2],bad[i][3],bad[i][4])||memcmp(backup,output,sizeof(output)))return 0;
  guards++;
 }
 if(op_celt_spread(0,8,-1,1,1,1))return 0;guards++;return 1;
}
int main(void){
 if(sizeof(Unquant)!=40)return 2;
 if(!invalid()){puts("Invalid PVQ request guard mismatch");return 1;}
 for(int n=1;n<=1024;n++)for(int pattern=0;pattern<8;pattern++){
  float x[1026],y[1026];
  for(int i=0;i<n;i++)x[i+1]=y[i+1]=pattern==0?0.0f:pattern==1?1.0E-20f:((int)(next()%20001)-10000)*0.00002f;
  y[0]=y[n+1]=123456.0f;
  float gain=(pattern%3)==0?0.0f:(next()%4096+1)/4096.0f;
  renormalise_vector(x+1,n,gain);
  if(!op_celt_renormalize(y+1,n,gain)||y[0]!=123456.0f||y[n+1]!=123456.0f||memcmp(x+1,y+1,n*sizeof(float))){printf("Renormalize mismatch N=%d pattern=%d\n",n,pattern);return 1;}
  renorms++;
 }
 {
  float x[2]={NAN,1.0f},copy[2];memcpy(copy,x,sizeof(x));
  if(op_celt_renormalize(x,2,1.0f)||memcmp(x,copy,sizeof(x)))return 1;guards++;
  x[0]=INFINITY;memcpy(copy,x,sizeof(x));
  if(op_celt_renormalize(x,2,1.0f)||memcmp(x,copy,sizeof(x)))return 1;guards++;
  if(op_celt_renormalize(x,0,1.0f)||op_celt_renormalize(x,1025,1.0f)||op_celt_renormalize(0,2,1.0f)||op_celt_renormalize(x,2,-.1f))return 1;guards+=4;
 }
 for(int n=2;n<=176;n++)for(int k=1;k<=128&&fits(n,k);k++)for(int B=1;B<=16;B*=2){
  if(n%B)continue;
  for(int spread=0;spread<=3;spread++)if(!pulse(n,k,spread,B,(next()&3)==0?0.0f:((next()%4096)+1)/4096.0f))return 1;
 }
 for(int n=192;n<=1024;n+=64)for(int k=1;k<14&&fits(n,k);k++)for(int B=1;B<=16;B*=2)for(int spread=0;spread<=3;spread++)if(!pulse(n,k,spread,B,1.0f))return 1;
 const int longk[]={256,1024,4096,16384,32767};
 for(unsigned i=0;i<sizeof(longk)/sizeof(longk[0]);i++)for(int spread=0;spread<=3;spread++)if(!pulse(2,longk[i],spread,1,1.0f))return 1;
 for(int n=2;n<=1024;n++)for(int B=1;B<=16;B*=2){
  if(n%B)continue;
  for(int spread=0;spread<=3;spread++)for(int dir=-1;dir<=1;dir+=2)if(!rotation(n,next()%16,spread,B,dir))return 1;
 }
 printf("Passed %u normalized pulse-vector/entropy comparisons, %u spreading comparisons, %u renormalization comparisons, %u invalid-request guards; peak error %.9g.\n",vectors,rotations,renorms,guards,max_error);return 0;
}
