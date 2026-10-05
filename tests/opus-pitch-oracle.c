/* Test-only normative standard-mode PLC pitch analysis comparisons. */
#include "lamp-test.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include "pitch.h"
typedef struct {const float *left,*right;void *work;int channels;unsigned input_cap,work_cap;} Pitch;
LAMP_ABI int op_celt_pitch(Pitch *);
static uint32_t rng=0x3249128f;
static uint32_t next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static unsigned checks,guards;
static unsigned long long coefficients;
static float max_error;
static int trial(int C,int pattern,int period){
 float x[2][2050],saved[2][2050],lp[1024];
 struct {uint64_t before;union {float f[3204];unsigned char b[12816];} value;uint64_t after;} scratch;
 for(int c=0;c<2;c++)for(int i=0;i<2050;i++)x[c][i]=123456.f;
 for(int c=0;c<C;c++)for(int i=0;i<2048;i++){
  float value;
  switch(pattern){
   case 0:value=0;break;
   case 1:value=1;break;
   case 2:value=32768*sinf((float)i*6.283185307179586f/period+(c*.5f));break;
   case 3:value=(i%period<period/2)?16384:-16384;break;
   case 4:value=((int)(next()%65536)-32768)*.3f;break;
   case 5:value=i%period==0?10000:0;break;
   case 6:value=(float)(sin(i*.27)+sin(i*.015))*(float)(i/2048.);break;
   case 7:value=((int)(next()%65536)-32768)*1e-20f;break;
   case 8:value=((int)(next()%65536)-32768)*1e7f;break;
   default:value=(c==0?1.f:-1.f)*16384*sinf((float)i*6.283185307179586f/period);break;
  }
  x[c][i+1]=value;
 }
 memcpy(saved,x,sizeof(x));memset(&scratch,0xa5,sizeof(scratch));
 scratch.before=0x13579bdf98765432ULL;scratch.after=0x2468ace012345678ULL;
 float *planes[2]={x[0]+1,x[1]+1};
 pitch_downsample(planes,lp,2048,C);
 int result;pitch_search(lp+360,lp,1328,620,&result);result=720-result;
 Pitch request={x[0]+1,C==2?x[1]+1:NULL,&scratch.value,C,2048,12816},backup=request;
 int actual=op_celt_pitch(&request);
 if(result!=actual||memcmp(&request,&backup,sizeof(request))||memcmp(x,saved,sizeof(x))||scratch.before!=0x13579bdf98765432ULL||scratch.after!=0x2468ace012345678ULL){printf("Pitch mismatch C=%d pattern=%d period=%d expected=%d actual=%d\n",C,pattern,period,result,actual);return 0;}
 for(int i=0;i<1024;i++){
  float error=fabsf(lp[i]-scratch.value.f[i])/fmaxf(1.f,fabsf(lp[i]));coefficients++;if(error>max_error)max_error=error;
  if(!isfinite(lp[i])||!isfinite(scratch.value.f[i])||error>.00001f){printf("Downsample mismatch %d %.9g/%.9g\n",i,lp[i],scratch.value.f[i]);return 0;}
 }
 checks++;return 1;
}
static int invalid(void){
 float left[2048]={0},right[2048]={0};unsigned char work[12816],saved[12816];memset(work,0xa5,sizeof(work));memcpy(saved,work,sizeof(work));
 Pitch good={left,right,work,2,2048,12816};
 for(unsigned k=0;k<11;k++){
  Pitch r=good;
  switch(k){case 0:r.left=NULL;break;case 1:r.right=NULL;break;case 2:r.work=NULL;break;case 3:r.channels=0;break;case 4:r.channels=3;break;case 5:r.input_cap=2047;break;case 6:r.work_cap=12815;break;case 7:left[2047]=NAN;break;case 8:right[0]=INFINITY;break;case 9:left[0]=1e20f;break;case 10:r.channels=-1;break;}
  Pitch backup=r;
  if(op_celt_pitch(&r)||memcmp(&r,&backup,sizeof(r))||memcmp(work,saved,sizeof(work))){printf("Pitch guard %u failed\n",k);return 0;}
  left[0]=left[2047]=right[0]=0;guards++;
 }
 if(op_celt_pitch(NULL))return 0;guards++;return 1;
}
int main(void){
 for(int repeat=0;repeat<4;repeat++)for(int C=1;C<=2;C++)for(int pattern=0;pattern<10;pattern++)for(int period=60;period<=780;period+=15)
  if(!trial(C,pattern,period))return 1;
 if(!invalid())return 1;
 printf("CELT pitch: %u mono/stereo downsample and exact pitch searches, %llu whitening coefficients, %u guards; max scaled error %.9g\n",checks,coefficients,guards,max_error);
 return 0;
}
