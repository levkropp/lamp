/* Optional BSD WavPack 5.9.0 encoder/decoder fixture oracle. Test-only. */
#include "lamp-test.h"
#include "wavpack.h"
static int block_output(void*id,void*data,int32_t bytes){return fwrite(data,1,bytes,(FILE*)id)==(size_t)bytes;}
static char*utf8(const lamp_char*path){
#ifdef _WIN32
 int n=WideCharToMultiByte(CP_UTF8,0,path,-1,NULL,0,NULL,NULL);char*p=malloc(n);if(p)WideCharToMultiByte(CP_UTF8,0,path,-1,p,n,NULL,NULL);return p;
#else
 return strdup(path);
#endif
}
int lamp_main(int argc,lamp_char**argv){
 /* Synthetic-vector generation only: request a proper prefix of a block
  * whose declared length is one sample longer. The final fixture receives
  * independently computed CRCs and must pass ordinary full reference decode. */
 if(argc==7&&!lamp_strcmp(argv[1],LT("prefix"))){
  FILE*mf=lamp_fopen(argv[2],LT("rb")),*cf=lamp_fopen(argv[3],LT("rb")),*out=lamp_fopen(argv[4],LT("wb"));if(!mf||!cf||!out)return 3;
  fseek(mf,0,SEEK_END);long mn=ftell(mf);rewind(mf);fseek(cf,0,SEEK_END);long cn=ftell(cf);rewind(cf);if(mn<32||cn<32||mn>1048584||cn>1048584)return 4;
  void*m=malloc(mn),*c=malloc(cn);if(!m||!c||fread(m,1,mn,mf)!=(size_t)mn||fread(c,1,cn,cf)!=(size_t)cn)return 5;fclose(mf);fclose(cf);char error[100];WavpackContext*w=WavpackOpenRawDecoder(m,mn,lamp_atoi(argv[6])?c:NULL,lamp_atoi(argv[6])?cn:0,0,error,0,0);if(!w){fprintf(stderr,"prefix: %s\n",error);return 6;}
  unsigned n=lamp_atoi(argv[5]),channels=WavpackGetNumChannels(w);if(n>150000||channels>8)return 7;int32_t*data=malloc((size_t)n*channels*4);unsigned got=WavpackUnpackSamples(w,data,n),errors=WavpackGetNumErrors(w);if(got!=n||errors){fprintf(stderr,"prefix got=%u wanted=%u errors=%u\n",got,n,errors);return 8;}if(fwrite(data,channels*4,n,out)!=n)return 9;fclose(out);WavpackCloseFile(w);free(m);free(c);free(data);return 0;
 }
 if(argc>1&&(!lamp_strcmp(argv[1],LT("encode"))||!lamp_strcmp(argv[1],LT("lossless")))){
  if(argc!=13)return 2;FILE*input=lamp_fopen(argv[2],LT("rb")),*main=lamp_fopen(argv[3],LT("wb")),*correction=lamp_fopen(argv[4],LT("wb"));if(!input||!main||!correction)return 3;
  WavpackConfig config={0};config.num_channels=lamp_atoi(argv[5]);config.bits_per_sample=lamp_atoi(argv[6]);config.bytes_per_sample=(config.bits_per_sample+7)/8;config.sample_rate=lamp_atoi(argv[7]);config.flags=lamp_atoi(argv[8]);if(!lamp_strcmp(argv[1],LT("encode")))config.flags|=CONFIG_HYBRID_FLAG|CONFIG_CREATE_WVC;
  int shape=lamp_atoi(argv[9]);if(shape!=9999){config.flags|=CONFIG_SHAPE_OVERRIDE;if(shape)config.flags|=CONFIG_HYBRID_SHAPE;else config.flags&=~CONFIG_HYBRID_SHAPE;config.shaping_weight=shape/1000.f;}
  config.bitrate=lamp_atoi(argv[10])/1000.f;config.block_samples=lamp_atoi(argv[11]);config.float_norm_exp=lamp_atoi(argv[12])?127:0;
  const int masks[]={0,4,3,7,0x33,0x37,0x3f,0x70f,0x63f};if(config.num_channels<1||config.num_channels>8)return 4;config.channel_mask=masks[config.num_channels];
  fseek(input,0,SEEK_END);long bytes=ftell(input);rewind(input);if(bytes<0||bytes%(config.num_channels*4)||bytes>64*1024*1024)return 4;
  int32_t*data=malloc(bytes?bytes:1);if(!data||fread(data,1,bytes,input)!=(size_t)bytes)return 5;fclose(input);
  WavpackContext*w=WavpackOpenFileOutput(block_output,main,correction);if(!w)return 6;
  if(!WavpackSetConfiguration64(w,&config,bytes/(config.num_channels*4),NULL)||!WavpackPackInit(w)||!WavpackPackSamples(w,data,(uint32_t)(bytes/(config.num_channels*4)))||!WavpackFlushSamples(w)){fprintf(stderr,"WavPack encode: %s\n",WavpackGetErrorMessage(w));return 7;}
  WavpackCloseFile(w);free(data);fclose(main);fclose(correction);printf("{\"result\":\"passed\",\"version\":\"%s\"}\n",WavpackGetLibraryVersionString());return 0;
 }
 if(argc==5&&!lamp_strcmp(argv[1],LT("decode"))){
  char error[100],*path=utf8(argv[2]);if(!path)return 3;WavpackContext*w=WavpackOpenFileInput(path,error,(lamp_atoi(argv[4])?OPEN_WVC:0)|OPEN_FILE_UTF8,0);free(path);if(!w){fprintf(stderr,"WavPack decode: %s\n",error);return 4;}
  FILE*out=lamp_fopen(argv[3],LT("wb"));if(!out)return 5;unsigned channels=WavpackGetNumChannels(w);if(channels>8)return 6;
  int32_t data[4096*8];uint64_t frames=0;unsigned n;while((n=WavpackUnpackSamples(w,data,4096))!=0){if(fwrite(data,channels*4,n,out)!=n)return 7;frames+=n;}fclose(out);
  unsigned errors=WavpackGetNumErrors(w);printf("{\"result\":\"%s\",\"version\":\"%s\",\"frames\":%llu,\"channels\":%u,\"rate\":%u,\"bits\":%u,\"mode\":%u,\"errors\":%u}\n",errors?"failed":"passed",WavpackGetLibraryVersionString(),(unsigned long long)frames,channels,WavpackGetSampleRate(w),WavpackGetBitsPerSample(w),WavpackGetMode(w),errors);WavpackCloseFile(w);return errors?8:0;
 }
 return 2;
}
