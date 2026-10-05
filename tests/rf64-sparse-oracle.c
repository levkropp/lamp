/* Original test-only NTFS sparse fixtures and 64-bit seek/output oracle. */
#include "lamp-test.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
LAMP_ABI int decoder_open(const lamp_char *);
LAMP_ABI void decoder_close(void);
LAMP_ABI uint64_t decoder_seek(uint64_t);
LAMP_ABI unsigned decoder_read(float *,unsigned);
extern uint64_t total_frames;
extern unsigned sample_rate,source_channels,source_bits,codec_kind,decode_error;
extern unsigned *ogg_cancel_ptr;
static uint64_t points[24],frames;
static unsigned count,B,C,F;
static void u32(unsigned char *p,uint32_t v){memcpy(p,&v,4);}
static void u64(unsigned char *p,uint64_t v){memcpy(p,&v,8);}
#define put lamp_sparse_put
static int marked(uint64_t frame){for(unsigned i=0;i<count;i++){uint64_t lo=points[i]>8?points[i]-8:0,hi=points[i]+512;if(frame>=lo&&frame<hi)return 1;}return 0;}
static double sample(uint64_t frame,unsigned ch){
 if(!marked(frame))return B==8?-1.0:0.0;
 uint32_t v=(uint32_t)(frame*2654435761ULL+ch*0x7654321U+0x13579bdfU);
 if(F)return (double)(int32_t)(v&0xffff)/65536.0-.5;
 if(B==8)return ((int)(unsigned char)v-128)/128.0;
 if(B==16)return (double)(int16_t)v/32768.0;
 if(B==24)return (double)((int32_t)(v<<8)>>8)/8388608.0;
 return (double)(int32_t)v/2147483648.0;
}
static SIZE_T committed(void){PROCESS_MEMORY_COUNTERS_EX p={0};p.cb=sizeof(p);return GetProcessMemoryInfo(GetCurrentProcess(),(PROCESS_MEMORY_COUNTERS *)&p,sizeof(p))?p.PrivateUsage:0;}
int lamp_main(int argc,lamp_char **argv){
 if(argc!=7)return 2;
 unsigned kind=lamp_atoi(argv[2]),mode=lamp_atoi(argv[6]);B=lamp_atoi(argv[3]);C=lamp_atoi(argv[4]);F=lamp_atoi(argv[5]);
 unsigned align=C*(B/8);frames=mode?8193:((1ULL<<33)/align+2053);
 if(!mode&&C==1)frames=(1ULL<<32)+2053;
 uint64_t reference=mode?0:((1ULL<<32)/align/48000)*48000;
 const uint64_t requests[]={0,1,4095,4096,(1ULL<<32)/align-9,(1ULL<<32)/align,(1ULL<<32)/align+9,(1ULL<<32)-1,1ULL<<32,reference,frames/2,frames-700,frames-1};
 for(unsigned i=0;i<sizeof(requests)/sizeof(*requests);i++)if(requests[i]<frames)points[count++]=requests[i];
 unsigned char header[256]={0},fmt[16]={0};memcpy(header,kind==1?"RF64":"BW64",4);u32(header+4,UINT32_MAX);memcpy(header+8,"WAVEds64",8);
 unsigned table=mode?2:0;u32(header+16,28+12*table);u64(header+28,frames*align);u64(header+36,kind==1?frames:UINT64_MAX);u32(header+44,table);
 uint64_t large1=(1ULL<<32)+17,large2=(1ULL<<32)+60;
 if(table){memcpy(header+48,mode==2?"TAIL":"JUNK",4);u64(header+52,mode==2?large2:large1);memcpy(header+60,"JUNK",4);u64(header+64,mode==2?large1:large2);}
 unsigned at=48+12*table;uint64_t data,fmt_at=at;
 if(mode==1)fmt_at+=8+large1+1+8+large2;
 memcpy(fmt,"\1\0",2);if(F)fmt[0]=3;fmt[2]=(unsigned char)C;u32(fmt+4,48000);u32(fmt+8,48000*align);fmt[12]=(unsigned char)align;fmt[14]=(unsigned char)B;
 data=fmt_at+24+8;uint64_t end=data+frames*align;if(mode==2)end+=8+large1+1+8+large2;
 if(end&1)end++;u64(header+20,end-8);
 lamp_file h;
 if(!lamp_sparse_create(argv[1],end,&h)||!put(h,0,header,at))return 2;
 unsigned char chunk[32]={0};memcpy(chunk,"fmt ",4);u32(chunk+4,16);memcpy(chunk+8,fmt,16);memcpy(chunk+24,"data",4);u32(chunk+28,UINT32_MAX);
 if(!put(h,fmt_at,chunk,32))return 2;
 if(mode){unsigned char c[8];memcpy(c,"JUNK",4);u32(c+4,UINT32_MAX);uint64_t p=mode==1?at:data+frames*align;if(!put(h,p,c,8))return 2;p+=8+large1+1;if(mode==2)memcpy(c,"TAIL",4);if(!put(h,p,c,8))return 2;}
 unsigned char raw[520*16];
 for(unsigned i=0;i<count;i++){
  uint64_t lo=points[i]>8?points[i]-8:0,hi=points[i]+512;if(hi>frames)hi=frames;
  for(uint64_t n=lo;n<hi;n++)for(unsigned c=0;c<C;c++){
   unsigned char *p=raw+((n-lo)*C+c)*(B/8);double value=sample(n,c);
   if(F){if(B==32){float v=(float)value;memcpy(p,&v,4);}else memcpy(p,&value,8);}
   else {int64_t v=B==8?(int64_t)(value*128+128):(int64_t)(value*(B==16?32768.0:B==24?8388608.0:2147483648.0));memcpy(p,&v,B/8);}
  }
  if(!put(h,data+lo*align,raw,(DWORD)((hi-lo)*align)))return 2;
 }
 uint64_t allocated;if(!lamp_sparse_close(h,argv[1],&allocated))return 2;if(!allocated||allocated>1024*1024)return 2;
 SYSTEM_INFO info;GetSystemInfo(&info);SIZE_T page=info.dwPageSize;DWORD old;unsigned char *guard=VirtualAlloc(NULL,6*page,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
 if(!guard||!VirtualProtect(guard+5*page,page,PAGE_NOACCESS,&old))return 2;
 unsigned checks=0;const unsigned caps[]={0,1,17,257};
 if(!decoder_open(argv[1])||total_frames!=frames||sample_rate!=48000||source_bits!=B||source_channels!=C||codec_kind!=1)return 1;
 for(unsigned i=0;i<count+3;i++)for(unsigned j=0;j<4;j++){
  uint64_t request=i<count?points[i]:i==count?frames:i==count+1?frames+1:UINT64_MAX,target=request>frames?frames:request;
  if(decoder_seek(request)!=target||decode_error)return 1;
  unsigned cap=caps[j],wanted=frames-target<cap?(unsigned)(frames-target):cap;unsigned char *out=guard+5*page-cap*8;memset(out,0xa5,cap*8);
  if(decoder_read((float *)out,cap)!=wanted||decode_error)return 1;
  for(unsigned n=0;n<wanted;n++)for(unsigned c=0;c<2;c++){float expected=(float)sample(target+n,C==1?0:c);if(memcmp(out+(n*2+c)*4,&expected,4)){fprintf(stderr,"PCM mismatch at %llu channel %u\n",target+n,c);return 1;}}
  for(unsigned n=wanted*8;n<cap*8;n++)if(out[n]!=0xa5)return 1;checks++;
 }
 unsigned cancel=1;ogg_cancel_ptr=&cancel;if(decoder_seek(UINT64_MAX)||decode_error)return 1;ogg_cancel_ptr=NULL;
 decoder_close();if(decoder_seek(1)||decoder_read((float *)(guard+5*page),1))return 1;
 ogg_cancel_ptr=&cancel;if(decoder_open(argv[1])||!decode_error)return 1;decoder_close();ogg_cancel_ptr=NULL;
 if(!decoder_open(argv[1]))return 1;ogg_cancel_ptr=&cancel;if(decoder_read((float *)(guard+5*page),1)||!decode_error)return 1;ogg_cancel_ptr=NULL;if(decoder_read((float *)(guard+5*page),1)||!decode_error)return 1;decoder_close();
 for(unsigned i=0;i<8;i++){if(!decoder_open(argv[1]))return 1;decoder_close();}SIZE_T before=committed();if(!before)return 2;
 for(unsigned i=0;i<64;i++){if(!decoder_open(argv[1]))return 1;decoder_close();}SIZE_T after=committed();if(after>before+page)return 1;
 lamp_char reference_path[32768];if(lamp_snprintf(reference_path,32768,LT("%s.channels.f32"),argv[1])<0)return 2;FILE *f=lamp_fopen(reference_path,LT("wb"));if(!f)return 2;
 for(unsigned n=0;n<257;n++)for(unsigned c=0;c<C;c++){float v=(float)sample(reference+n,c);if(fwrite(&v,4,1,f)!=1)return 2;}fclose(f);VirtualFree(guard,0,MEM_RELEASE);
 printf("{\"result\":\"passed\",\"frames\":%llu,\"logical_bytes\":%llu,\"allocated_bytes\":%llu,\"data_offset\":%llu,\"seek_checks\":%u,\"cancel_checks\":3,\"reopen_checks\":64,\"reference_frame\":%llu,\"reference_seconds\":%llu,\"private_bytes_before\":%llu,\"private_bytes_after\":%llu}\n",frames,end,allocated,data,checks,reference,reference/48000,(uint64_t)before,(uint64_t)after);return 0;
}
