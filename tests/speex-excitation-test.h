/* Test-only reference interception, never linked into a player. */
#ifndef LAMP_SPEEX_EXCITATION_TEST_H
#define LAMP_SPEEX_EXCITATION_TEST_H
#include "speex/speex_bits.h"
#include <stdint.h>
typedef void (*SpxPitchRef)(float*,float*,int,int,float,const void*,int,int*,float*,SpeexBits*,char*,int,int,float,int);
typedef void (*SpxInnovationRef)(float*,const void*,int,SpeexBits*,char*,uint32_t*);
void test_speex_pitch(int,SpxPitchRef,float*,float*,int,int,float,const void*,int,int*,float*,SpeexBits*,char*,int,int,float,int);
void test_speex_innovation(int,SpxInnovationRef,float*,const void*,int,SpeexBits*,char*,uint32_t*);
void spxref_pitch_unquant_3tap(float*,float*,int,int,float,const void*,int,int*,float*,SpeexBits*,char*,int,int,float,int);
void spxref_forced_pitch_unquant(float*,float*,int,int,float,const void*,int,int*,float*,SpeexBits*,char*,int,int,float,int);
void spxref_split_cb_shape_sign_unquant(float*,const void*,int,SpeexBits*,char*,uint32_t*);
void spxref_noise_codebook_unquant(float*,const void*,int,SpeexBits*,char*,uint32_t*);
#endif
