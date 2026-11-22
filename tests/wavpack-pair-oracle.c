/* Test-only guarded native-frame caller for paired WavPack reconstruction. */
#include "lamp-test.h"
LAMP_ABI int wv_track_open(const void*,unsigned,const void*,unsigned);
LAMP_ABI int wv_track_decode_pair(const void*,unsigned,const void*,unsigned,float*,unsigned);
LAMP_ABI void wv_track_close(void);
extern unsigned decode_error;
static uint32_t u32(const unsigned char*p){return(uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
typedef struct{unsigned char*allocation,*data;size_t size,allocated;} Guard;
static int guard(Guard*g,size_t bytes){SYSTEM_INFO i;GetSystemInfo(&i);size_t page=i.dwPageSize,body=(bytes+page-1)/page*page;g->allocated=body+page*2;g->allocation=VirtualAlloc(NULL,g->allocated,MEM_RESERVE|MEM_COMMIT,PAGE_NOACCESS);DWORD old;if(!g->allocation||!VirtualProtect(g->allocation+page,body,PAGE_READWRITE,&old))return 0;g->data=g->allocation+page+body-bytes;g->size=bytes;return 1;}
static int load(const lamp_char*path,Guard*g){FILE*f=lamp_fopen(path,LT("rb"));if(!f)return 0;fseek(f,0,SEEK_END);long n=ftell(f);rewind(f);if(n<32||n>64*1024*1024||!guard(g,n)||fread(g->data,1,n,f)!=(size_t)n){fclose(f);return 0;}fclose(f);return 1;}
static int frame(Guard*g,size_t*position,const unsigned char**start,unsigned*bytes,unsigned*samples){
 size_t begin=0;while(*position+32<=g->size){const unsigned char*p=g->data+*position;uint32_t block=u32(p+4),n=u32(p+20),flags=u32(p+24);if(memcmp(p,"wvpk",4)||block<24||block>1048576||(size_t)block+8>g->size-*position)return -1;if(!begin&&!n){*position+=block+8;continue;}if(!begin){begin=*position+1;*samples=n;}*position+=block+8;if(flags&0x1000){*start=g->data+begin-1;*bytes=(unsigned)(*position-begin+1);return 1;}}
 return *position==g->size?0:-1;
}
int lamp_main(int argc,lamp_char**argv){
 if(argc!=4)return 2;Guard main={0},correction={0};if(!load(argv[1],&main)||!load(argv[2],&correction))return 3;FILE*out=lamp_fopen(argv[3],LT("wb"));if(!out)return 4;
 size_t mp=0,cp=0;unsigned mb,cb,ms,cs;const unsigned char*m,*c;int opened=0,status=0;uint64_t frames=0;unsigned blocks=0,contracts=0;
 while((status=frame(&main,&mp,&m,&mb,&ms))==1){if(frame(&correction,&cp,&c,&cb,&cs)!=1||cs!=ms){status=-1;break;}if(!opened){if(!wv_track_open(NULL,0,m,mb)){status=-1;break;}opened=1;}
  Guard output={0};if(!guard(&output,(size_t)ms*8+64)){status=-1;break;}memset(output.data,0xa5,64);
  if(!blocks){
   /* Invalid bounds must fail before any PCM output, including arithmetic
      overflow without touching that deliberately invalid input pointer. */
   for(unsigned trial=0;trial<6;trial++){
    const void*input=c;unsigned bytes=cb,capacity=ms;
    if(trial==0)capacity=ms-1;
    if(trial==1)input=NULL;
    if(trial==2)bytes=31;
    if(trial==3){input=(const void*)(UINTPTR_MAX-15);bytes=32;}
    if(trial==4)bytes=cb-1;
    if(trial==5){if(cp>=correction.size)continue;bytes=cb+1;}
    memset(output.data,0xa5,output.size);decode_error=0;
    if(wv_track_decode_pair(m,mb,input,bytes,(float*)(output.data+64),capacity)!=-1||!decode_error)abort();
    for(size_t j=0;j<output.size;j++)if(output.data[j]!=0xa5)abort();contracts++;
   }
   decode_error=0;
  }
  int n=wv_track_decode_pair(m,mb,c,cb,(float*)(output.data+64),ms);for(unsigned j=0;j<64;j++)if(output.data[j]!=0xa5)abort();if(n!=(int)ms){VirtualFree(output.allocation,0,MEM_RELEASE);status=-1;break;}
  if(fwrite(output.data+64,8,n,out)!=(unsigned)n){status=-1;VirtualFree(output.allocation,0,MEM_RELEASE);break;}VirtualFree(output.allocation,0,MEM_RELEASE);frames+=n;blocks++;
 }
 fclose(out);if(opened)wv_track_close();VirtualFree(main.allocation,0,MEM_RELEASE);VirtualFree(correction.allocation,0,MEM_RELEASE);
 printf("{\"result\":\"%s\",\"frames\":%llu,\"packets\":%u,\"contract_rejections\":%u,\"decode_error\":%u}\n",status<0||decode_error?"failed":"passed",(unsigned long long)frames,blocks,contracts,decode_error);return status<0||decode_error?1:0;
}
