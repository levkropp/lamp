/* Official RFC8251 vector input; assembly packet PCM/history checked against
   the hash-patched normative reference. C is confined to this test binary. */
#define OPUS_STREAM_ORACLE_EMBEDDED
#define OPUS_STREAM_VECTOR_OBSERVER
#include "opus-stream-oracle.c"

static uint32_t vector_be32(const unsigned char *p){
 return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3];
}
int main(int argc,char **argv){
 if(argc!=5){fprintf(stderr,"Usage: opus-conformance-oracle input.bit output.s16 rate channels\n");return 2;}
 int rate=atoi(argv[3]),channels=atoi(argv[4]);
 if((rate!=8000&&rate!=12000&&rate!=16000&&rate!=24000&&rate!=48000)||(channels!=1&&channels!=2))return 2;
 FILE *input=fopen(argv[1],"rb"),*output=fopen(argv[2],"wb");
 if(!input||!output){fprintf(stderr,"Cannot open vector input/output\n");if(input)fclose(input);if(output)fclose(output);return 2;}
 if(!mode_reset(channels,rate))return 1;
 unsigned char header[8],packet[65536];int16_t pcm[11520];unsigned packets=0;unsigned long long frames=0;
 for(;;){
  size_t size=fread(header,1,8,input);
  if(!size){if(ferror(input)){fprintf(stderr,"Vector input read failed\n");return 1;}break;}
  if(size!=8){fprintf(stderr,"Truncated vector header\n");return 1;}
  uint32_t len=vector_be32(header),range=vector_be32(header+4);
  if(len>sizeof(packet)||fread(packet,1,len,input)!=len){fprintf(stderr,"Truncated/oversized vector packet %u\n",packets);return 1;}
  unsigned long long prior=sp_samples;
  if(!sp_decode(len?packet:NULL,len,rate*120/1000,0,0)){fprintf(stderr,"Vector packet %u mismatch\n",packets);return 1;}
  unsigned samples=(unsigned)(sp_samples-prior);
  if(range&&ms.range!=range){fprintf(stderr,"Vector packet %u final range %08x != %08x\n",packets,ms.range,range);return 1;}
  for(unsigned i=0;i<samples;i++)pcm[i]=FLOAT2INT16(sp_vector_pcm[i]);
  if(fwrite(pcm,2,samples,output)!=samples){fprintf(stderr,"Vector output write failed\n");return 1;}
  frames+=samples/channels;packets++;
 }
 if(fclose(input)||fclose(output)||!packets)return 1;
 free(mr);mr=NULL;
 printf("{\"result\":\"passed\",\"packets\":%u,\"frames\":%llu,\"rate\":%d,\"channels\":%d,\"history_values\":%llu,\"maximum_scaled_error\":%.9g}\n",packets,frames,rate,channels,mode_values,mode_max);
 return 0;
}
