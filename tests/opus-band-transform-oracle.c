/* Test-only comparison with normative BSD CELT Haar/Hadamard transforms. */
#include "lamp-test.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "bands.c"
typedef struct{float *x;int n0,stride,hadamard,inverse;} Reorder;
LAMP_ABI int op_celt_haar(float *,int,int);
LAMP_ABI int op_celt_reorder(Reorder *);
static uint32_t seed=0x62758193;
static uint32_t next(void){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;}
int main(void){
 unsigned haar_checks=0,reorder_checks=0,guards=0;
 if(sizeof(Reorder)!=24)return 2;
 for(int stride=1;stride<=1024;stride++)for(int n0=2;n0*stride<=1024;n0+=2){
  float x[1026],y[1026];int n=n0*stride;
  for(int i=0;i<n;i++)x[i+1]=y[i+1]=((int)(next()%20001)-10000)*0.00002f;
  y[0]=y[n+1]=123456.0f;
  haar1(x+1,n0,stride);
  if(!op_celt_haar(y+1,n0,stride)||memcmp(x+1,y+1,n*sizeof(float))||y[0]!=123456.0f||y[n+1]!=123456.0f){printf("Haar mismatch N0=%d stride=%d\n",n0,stride);return 1;}
  haar_checks++;
 }
 for(int stride=1;stride<=16;stride*=2)for(int n0=1;n0*stride<=1024;n0++)for(int had=0;had<=1;had++){
  if(had&&stride==1)continue;
  int n=n0*stride;float x[1026],y[1026],original[1024];
  for(int i=0;i<n;i++){uint32_t bits=next();memcpy(x+1+i,&bits,4);memcpy(y+1+i,&bits,4);}
  memcpy(original,x+1,n*4);y[0]=y[n+1]=123456.0f;
  Reorder req={y+1,n0,stride,had,0};
  deinterleave_hadamard(x+1,n0,stride,had);
  if(!op_celt_reorder(&req)||memcmp(x+1,y+1,n*4)||y[0]!=123456.0f||y[n+1]!=123456.0f){printf("Deinterleave mismatch N0=%d stride=%d had=%d\n",n0,stride,had);return 1;}
  reorder_checks++;
  req.inverse=1;interleave_hadamard(x+1,n0,stride,had);
  if(!op_celt_reorder(&req)||memcmp(x+1,y+1,n*4)||memcmp(original,y+1,n*4)||y[0]!=123456.0f||y[n+1]!=123456.0f){puts("Interleave/inverse mismatch");return 1;}
  reorder_checks++;
 }
 float x[1024],copy[1024];for(int i=0;i<1024;i++)x[i]=123.0f;memcpy(copy,x,sizeof(x));
 const int haar_bad[][2]={{0,1},{1,1},{3,1},{1025,1},{2,0},{2,1025},{2,513}};
 for(unsigned i=0;i<sizeof(haar_bad)/sizeof(haar_bad[0]);i++){if(op_celt_haar(x,haar_bad[i][0],haar_bad[i][1])||memcmp(x,copy,sizeof(x)))return 1;guards++;}
 if(op_celt_haar(0,2,1))return 1;guards++;
 const int bad[][4]={{0,1,0,0},{1025,1,0,0},{1,0,0,0},{1,3,0,0},{1,32,0,0},{65,16,0,0},{1,1,1,0},{1,2,2,0},{1,2,0,2}};
 for(unsigned i=0;i<sizeof(bad)/sizeof(bad[0]);i++){Reorder q={x,bad[i][0],bad[i][1],bad[i][2],bad[i][3]},saved=q;if(op_celt_reorder(&q)||memcmp(x,copy,sizeof(x))||memcmp(&q,&saved,sizeof(q)))return 1;guards++;}
 Reorder q={0,1,2,0,0};if(op_celt_reorder(&q)||op_celt_reorder(0))return 1;guards+=2;
 printf("Passed %u Haar comparisons, %u layout/inverse comparisons, %u invalid-request guards.\n",haar_checks,reorder_checks,guards);return 0;
}
