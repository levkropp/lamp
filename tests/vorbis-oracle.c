/* Test-only MIT reference decoder. Never linked into LAMP. */
#define STB_VORBIS_NO_PUSHDATA_API
#include "reference/stb_vorbis.c"
#include <stdio.h>
int main(int argc,char **argv) {
    if(argc!=3) return 1;
    int error=0;
    stb_vorbis *v=stb_vorbis_open_filename(argv[1],&error,NULL);
    if(!v) return 2;
    FILE *out=fopen(argv[2],"wb");
    if(!out) return 3;
    int channels=stb_vorbis_get_info(v).channels;
    float pcm[8192],stereo[8192];
    int n;
    while((n=stb_vorbis_get_samples_float_interleaved(v,channels,pcm,8192))>0) {
        if(channels==1){for(int i=0;i<n;i++)stereo[2*i]=stereo[2*i+1]=pcm[i];fwrite(stereo,sizeof(float)*2,n,out);}
        else fwrite(pcm,sizeof(float)*2,n,out);
    }
    error=stb_vorbis_get_error(v);
    stb_vorbis_close(v);
    fclose(out);
    return error?4:0;
}
