/* Test-only BSD Xiph float reference; never linked into the player. */
#include <vorbis/vorbisfile.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include <math.h>
#include "mdct.h"
// Original spectrum-level oracle: independent spec residue/floor construction
// supplies these planes; the unmodified Xiph inverse MDCT supplies the transform.
static int spectra_reference(const wchar_t *input,const wchar_t *output){
 FILE *in=_wfopen(input,L"rb"),*out=_wfopen(output,L"wb");unsigned header[3];
 if(!in||!out||fread(header,sizeof(header),1,in)!=1)return 2;
 unsigned C=header[0],N=header[1],F=header[2],H=N/2;
 if(!C||C>255||N<64||N>8192||(N&(N-1))||F<2||F>5)return 2;
 float *s=malloc(H*4),*t=malloc(N*4),*previous=calloc(C*H,4),*pcm=malloc(C*H*4);
 double *window=malloc(H*sizeof(double));if(!s||!t||!previous||!pcm||!window)return 2;
 const double pi=acos(-1.);for(unsigned i=0;i<H;i++){double x=sin(pi*(i+.5)/N);window[i]=sin(pi*.5*x*x);}
 mdct_lookup lookup;mdct_init(&lookup,N);
 for(unsigned f=0;f<F;f++){
  for(unsigned c=0;c<C;c++){
   if(fread(s,H*4,1,in)!=1)return 2;mdct_backward(&lookup,s,t);
   for(unsigned i=0;i<H;i++){pcm[i*C+c]=(float)(t[i]*window[i]+previous[c*H+i]*window[H-i-1]);previous[c*H+i]=t[H+i];}
  }
  if(f&&fwrite(pcm,C*H*4,1,out)!=1)return 2;
 }
 int extra=fgetc(in);mdct_clear(&lookup);fclose(in);fclose(out);free(s);free(t);free(previous);free(pcm);free(window);return extra==EOF?0:2;
}
int wmain(int argc,wchar_t **argv){
 if(argc==4&&!wcscmp(argv[1],L"--spectra"))return spectra_reference(argv[2],argv[3]);
 if(argc!=3)return 2;
 FILE *in=_wfopen(argv[1],L"rb"),*out=_wfopen(argv[2],L"wb");if(!in||!out)return 2;
 OggVorbis_File v;int error=ov_open(in,&v,NULL,0);if(error){fprintf(stderr,"Xiph open error %d\n",error);return 1;}
 unsigned channels=ov_info(&v,-1)->channels;float *buffer=malloc(channels*257*sizeof(float));if(!buffer)return 2;
 long n;int stream;float **pcm;
 while((n=ov_read_float(&v,&pcm,257,&stream))>0){
  for(long i=0;i<n;i++)for(unsigned c=0;c<channels;c++)buffer[i*channels+c]=pcm[c][i];
  if(fwrite(buffer,channels*sizeof(float),n,out)!=(size_t)n)return 2;
 }
 ov_clear(&v);fclose(out);free(buffer);if(n<0)fprintf(stderr,"Xiph decode error %ld\n",n);return n<0?1:0;
}
