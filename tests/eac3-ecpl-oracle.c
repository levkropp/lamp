/* Test-only literal A/52 E.3.5.5 math, using direct cosine sums and DFT.
   ECPL_REFERENCE builds only this portable reference, including on ARM.
   The default build calls the shipping assembly with guarded memory. */
#include "lamp-test.h"
#include <math.h>
#include <stddef.h>

typedef struct {
    uint32_t count, flags;
    int32_t edges[23];
    uint8_t amp[22], angle[22], chaos[22];
} Coordinates;
typedef char coordinate_abi_check[(sizeof(Coordinates) == 168 && offsetof(Coordinates, amp) == 100 &&
    offsetof(Coordinates, angle) == 122 && offsetof(Coordinates, chaos) == 144) ? 1 : -1];

#ifndef ECPL_REFERENCE
LAMP_ABI void eac3_ecpl_carrier(const float *, const float *, const float *, double *);
LAMP_ABI int eac3_ecpl_channel(const double *, const Coordinates *, float *, const float *);
#endif

static const double pi = 3.1415926535897932384626433832795;
static double imdct_cos[512][256], dft_cos[256][512], dft_sin[256][512], window[512];

static void init_reference(void) {
    /* Independently derive the KBD window, rounding once to the runtime's
       float32 window precision. No assembly tables, FFT or DCT-IV are read. */
    double kaiser[257], sum=0, cumulative=0;
    for (unsigned n=0; n<=256; n++) {
        double x2 = pow(5*pi/256, 2) * n * (256-n), term=1, value=1;
        for (unsigned j=1; j<60; j++) { term *= x2/(j*j); value += term; }
        kaiser[n]=value; sum+=value;
    }
    for (unsigned n=0; n<256; n++) {
        cumulative+=kaiser[n];
        window[n]=window[511-n]=(float)sqrt(cumulative/sum);
    }
    for (unsigned n=0; n<512; n++)
        for (unsigned k=0; k<256; k++)
            imdct_cos[n][k]=-cos(2*pi/512*(n+.5+128)*(k+.5));
    for (unsigned k=0; k<256; k++)
        for (unsigned n=0; n<512; n++) {
            dft_cos[k][n]=cos(2*pi*k*n/512);
            dft_sin[k][n]=-sin(2*pi*k*n/512);
        }
}

static void reference_carrier(const float *spectra, double *z) {
    double time[3][512], real[512], imag[512];
    for (unsigned block=0; block<3; block++)
        for (unsigned n=0; n<512; n++) {
            double sum=0;
            for (unsigned k=0; k<256; k++) sum+=spectra[block*256+k]*imdct_cos[n][k];
            time[block][n]=sum*window[n];
        }
    for (unsigned n=0; n<512; n++) {
        double pcm = n<256 ? time[0][n+256]+time[1][n] : time[1][n]+time[2][n-256];
        real[n]=pcm*window[n]*cos(pi*n/512);
        imag[n]=pcm*window[n]*(-sin(pi*n/512));
    }
    for (unsigned k=0; k<256; k++) {
        double r=0,i=0;
        for (unsigned n=0; n<512; n++) {
            r+=real[n]*dft_cos[k][n]-imag[n]*dft_sin[k][n];
            i+=imag[n]*dft_cos[k][n]+real[n]*dft_sin[k][n];
        }
        z[2*k]=r/512; z[2*k+1]=i/512;
    }
}

static double wrap(double angle) {
    while (angle>1) angle-=2;
    while (angle<-1) angle+=2;
    return angle;
}

static int reference_channel(const double *z, const Coordinates *c, float *out, const float *random) {
    if (c->count<1 || c->count>22 || c->flags&~7u || c->edges[0]<13) return 0;
    for (unsigned b=0; b<c->count; b++)
        if (c->edges[b+1]<=c->edges[b] || c->edges[b+1]>253 ||
            c->amp[b]>31 || c->angle[b]>63 || c->chaos[b]>7) return 0;
    const double chaos_table[8]={0,-.142857,-.285714,-.428571,-.571429,-.714286,-.857143,-1};
    const unsigned mantissas[4]={27,23,19,16};
    double amp[22], angle[22], chaos[22], center[22], phase[256];
    for (unsigned b=0; b<c->count; b++) {
        unsigned a=c->amp[b];
        amp[b]=a==31 ? 0 : a==0 ? 1 : ldexp((double)mantissas[(a-1)%4]/32,-(int)((a-1)/4));
        angle[b]=c->flags&1 ? 0 : (c->angle[b]<32 ? (int)c->angle[b] : (int)c->angle[b]-64)/32.0;
        chaos[b]=c->flags&1 ? 0 : chaos_table[c->chaos[b]];
        if (!(c->flags&3)) amp[b]*=1+.38*chaos[b];
        center[b]=(c->edges[b]+c->edges[b+1]-1)/2.0;
        for (int k=c->edges[b]; k<c->edges[b+1]; k++) phase[k]=angle[b];
    }
    /* Literal pseudocode's progression: interpolate from each center to the
       next, extrapolating the lower and upper half of the endpoint bands. */
    if ((c->flags&4) && c->count>1) {
        for (unsigned b=1; b<c->count; b++) {
            double delta=wrap(angle[b]-angle[b-1]);
            double slope=delta/(center[b]-center[b-1]);
            int begin=b==1 ? c->edges[0] : (int)ceil(center[b-1]);
            int end=b+1==c->count ? c->edges[c->count] : (int)ceil(center[b]);
            for (int k=begin; k<end; k++) phase[k]=wrap(angle[b-1]+slope*(k-center[b-1]));
        }
    }
    for (unsigned b=0; b<c->count; b++)
        for (int k=c->edges[b]; k<c->edges[b+1]; k++) {
            double p=phase[k]+chaos[b]*random[k];
            if (p<-1) p+=2; else if (p>=1) p-=2;
            double cosine=cos(pi*p), sine=sin(pi*p);
            double r=z[2*k]*cosine-z[2*k+1]*sine;
            double i=z[2*k+1]*cosine+z[2*k]*sine;
            double y=cos(2*pi*(128+.5)/512*(k+.5));
            double yr=cos(2*pi*(128+.5)/512*(255-k+.5));
            out[k]=(float)(-2*amp[b]*(y*r+yr*i));
        }
    return 1;
}

#ifndef ECPL_REFERENCE
typedef struct { unsigned char *base, *data; size_t bytes, usable; int input; } Guard;
static Guard guarded(size_t bytes, int input) {
    SYSTEM_INFO info; GetSystemInfo(&info); size_t page=info.dwPageSize;
    size_t usable=(bytes+16+page-1)/page*page;
    Guard g={VirtualAlloc(NULL,usable+2*page,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE),NULL,bytes,usable,input};
    DWORD old;
    if (!g.base || !VirtualProtect(g.base,page,PAGE_NOACCESS,&old) ||
        !VirtualProtect(g.base+page+usable,page,PAGE_NOACCESS,&old)) exit(2);
    g.data=g.base+page+usable-bytes-(input ? 0 : 8);
    memset(g.data-8,0xa5,8);
    if (!input) memset(g.data+bytes,0xa5,8);
    return g;
}
static void readonly(Guard *g) {
    SYSTEM_INFO info; GetSystemInfo(&info); DWORD old;
    if (!VirtualProtect(g->base+info.dwPageSize,g->usable,PAGE_READONLY,&old)) exit(2);
}
static int intact(const Guard *g) {
    for (int n=0;n<8;n++) if (g->data[n-8]!=0xa5 || (!g->input && g->data[g->bytes+n]!=0xa5)) return 0;
    return 1;
}
#endif

int lamp_main(int argc, lamp_char **argv) {
    if (argc!=3) return 2;
    FILE *input=lamp_fopen(argv[1],LT("rb"));
#ifdef ECPL_REFERENCE
    FILE *reference=lamp_fopen(argv[2],LT("wb"));
    init_reference();
#else
    FILE *reference=lamp_fopen(argv[2],LT("rb"));
    Guard in[3], random=guarded(256*4,1), coords=guarded(sizeof(Coordinates),1),
        carrier=guarded(512*8,0), output=guarded(256*4,0);
    for (unsigned b=0;b<3;b++) in[b]=guarded(256*4,1);
#endif
    uint32_t cases;
    if (!input || !reference || fread(&cases,4,1,input)!=1 || cases>10000) return 2;
    double maximum_carrier=0, maximum_channel=0, maximum_identity=0;
    unsigned identity_cases=0;
    for (unsigned row=0;row<cases;row++) {
        float spectra[768], noise[256], initial[256], expected[256]; Coordinates c;
        double z[512]; uint32_t valid;
        if (fread(spectra,sizeof spectra,1,input)!=1 || fread(&c,sizeof c,1,input)!=1 ||
            fread(noise,sizeof noise,1,input)!=1 || fread(initial,sizeof initial,1,input)!=1) return 2;
#ifdef ECPL_REFERENCE
        reference_carrier(spectra,z);
        memcpy(expected,initial,sizeof expected);
        valid=reference_channel(z,&c,expected,noise);
        if (fwrite(&valid,4,1,reference)!=1 || fwrite(z,sizeof z,1,reference)!=1 ||
            fwrite(expected,sizeof expected,1,reference)!=1) return 2;
#else
        if (fread(&valid,4,1,reference)!=1 || fread(z,sizeof z,1,reference)!=1 ||
            fread(expected,sizeof expected,1,reference)!=1) return 2;
        /* Re-protect populated inputs on each iteration. Canary allocations
           deliberately place complex doubles at an 8-byte, not 16-byte boundary. */
        Guard *all[5]={&in[0],&in[1],&in[2],&random,&coords};
        SYSTEM_INFO info; GetSystemInfo(&info); DWORD old;
        for (unsigned j=0;j<5;j++) if (!VirtualProtect(all[j]->base+info.dwPageSize,
            all[j]->usable,PAGE_READWRITE,&old)) return 2;
        for (unsigned b=0;b<3;b++) memcpy(in[b].data,spectra+b*256,256*4);
        memcpy(random.data,noise,sizeof noise); memcpy(coords.data,&c,sizeof c);
        for (unsigned j=0;j<5;j++) readonly(all[j]);
        if (!VirtualProtect(carrier.base+info.dwPageSize,carrier.usable,PAGE_READWRITE,&old)) return 2;
        eac3_ecpl_carrier((float *)in[0].data,(float *)in[1].data,(float *)in[2].data,(double *)carrier.data);
        double peak=0,scale=1e-8;
        for (unsigned k=0;k<512;k++) {
            double value=((double *)carrier.data)[k];
            if (!isfinite(value)) return 1;
            peak=fmax(peak,fabs(value-z[k])); scale=fmax(scale,fabs(z[k]));
        }
        maximum_carrier=fmax(maximum_carrier,peak);
        if (peak>2e-12*scale) { fprintf(stderr,"carrier row %u: %.9g / %.9g\n",row,peak,scale); return 1; }
        readonly(&carrier);
        memcpy(output.data,initial,sizeof initial);
        int result=eac3_ecpl_channel((double *)carrier.data,(Coordinates *)coords.data,(float *)output.data,(float *)random.data);
        if (result!=(int)valid) { fprintf(stderr,"status row %u\n",row); return 1; }
        peak=0; scale=1e-8;
        for (unsigned k=0;k<256;k++) {
            float value=((float *)output.data)[k];
            if (!isfinite(value)) return 1;
            if ((!valid || k<(unsigned)c.edges[0] || k>=(unsigned)c.edges[c.count]) &&
                memcmp(&value,&initial[k],4)) { fprintf(stderr,"outside range row %u bin %u\n",row,k); return 1; }
            if (valid && k>=(unsigned)c.edges[0] && k<(unsigned)c.edges[c.count]) {
                peak=fmax(peak,fabs((double)value-expected[k])); scale=fmax(scale,fabs(expected[k]));
            }
        }
        maximum_channel=fmax(maximum_channel,peak);
        if (peak>2e-7*scale) { fprintf(stderr,"channel row %u: %.9g / %.9g\n",row,peak,scale); return 1; }
        /* Keep the literal overlap normalization observable. This assertion
           would fail if the carrier silently gained an extra factor of 2. */
        int identity=valid;
        for (unsigned b=0;identity && b<c.count;b++)
            if (c.amp[b] || c.angle[b] || c.chaos[b]) identity=0;
        if (identity) {
            double error=0, amplitude=1e-8;
            for (unsigned k=0;k<768;k++) amplitude=fmax(amplitude,fabs(spectra[k]));
            for (int k=c.edges[0];k<c.edges[c.count];k++)
                error=fmax(error,fabs(((float *)output.data)[k]-.5*spectra[256+k]));
            if (error>2e-7*amplitude) { fprintf(stderr,"identity row %u: %.9g / %.9g\n",row,error,amplitude); return 1; }
            maximum_identity=fmax(maximum_identity,error); identity_cases++;
        }
        if (!intact(&carrier) || !intact(&output)) return 1;
        for (unsigned j=0;j<5;j++) if (!intact(all[j])) return 1;
#endif
    }
    if (fgetc(input)!=EOF) return 2;
#ifndef ECPL_REFERENCE
    if (fgetc(reference)!=EOF) return 2;
    for (unsigned b=0;b<3;b++) VirtualFree(in[b].base,0,MEM_RELEASE);
    VirtualFree(random.base,0,MEM_RELEASE); VirtualFree(coords.base,0,MEM_RELEASE);
    VirtualFree(carrier.base,0,MEM_RELEASE); VirtualFree(output.base,0,MEM_RELEASE);
#endif
    if (fclose(input) || fclose(reference)) return 2;
    printf("{\"result\":\"passed\",\"cases\":%u,\"maximum_carrier_error\":%.17g,\"maximum_channel_error\":%.17g,"
        "\"identity_cases\":%u,\"maximum_half_gain_identity_error\":%.17g}\n",
        cases,maximum_carrier,maximum_channel,identity_cases,maximum_identity);
    return 0;
}
