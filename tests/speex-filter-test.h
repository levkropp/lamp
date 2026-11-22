/* Test-only interception of unmodified Speex C kernels. No runtime link. */
#ifndef LAMP_SPEEX_FILTER_TEST_H
#define LAMP_SPEEX_FILTER_TEST_H
typedef void (*SpxRefLpc)(const float*,float*,int,char*);
typedef void (*SpxRefInterpolate)(float*,float*,float*,int,int,int,float);
typedef void (*SpxRefBw)(float,const float*,float*,int);
typedef void (*SpxRefIir)(const float*,const float*,float*,int,int,float*,char*);
typedef void (*SpxRefHighpass)(const float*,float*,int,int,float*);
void test_speex_lpc(SpxRefLpc,const float*,float*,int,char*);
void test_speex_interpolate(SpxRefInterpolate,float*,float*,float*,int,int,int,float);
void test_speex_bw(SpxRefBw,float,const float*,float*,int);
void test_speex_iir(SpxRefIir,const float*,const float*,float*,int,int,float*,char*);
void test_speex_highpass(SpxRefHighpass,const float*,float*,int,int,float*);
void spxref_lsp_to_lpc(const float*,float*,int,char*);
void spxref_lsp_interpolate(float*,float*,float*,int,int,int,float);
void spxref_bw_lpc(float,const float*,float*,int);
void spxref_iir_mem16(const float*,const float*,float*,int,int,float*,char*);
void spxref_highpass(const float*,float*,int,int,float*);
#endif
