/* Ogg/Opus bridge oracle. Encoder and native decoder are test-only. */
#define OPUS_STREAM_OGG_EMBEDDED
#define OPUS_STREAM_ORACLE_EMBEDDED
#include "opus-stream-oracle.c"
uint64_t total_frames;
unsigned sample_rate,source_channels,source_bits,decode_error;
int opus_open(const unsigned char *,const unsigned char *);
int opus_headers(const unsigned char *,const unsigned char *);
const unsigned char *ogg_next(void);
extern unsigned op_preskip;
int opus_read(float *,unsigned);
void opus_close(void),ogg_close(void);
static unsigned og_cases,og_rejects,og_checks,og_late,og_cancel;
static unsigned long long og_samples;
static float og_max;
static unsigned char og_file[1048576],og_saved[1048576];
static unsigned og_bytes,og_sequence,og_audio_pages[256],og_audio_count;
static uint32_t og_crc(const unsigned char *data,unsigned bytes){
 uint32_t crc=0;for(unsigned i=0;i<bytes;i++){crc^=(uint32_t)(i>=22&&i<26?0:data[i])<<24;for(int j=0;j<8;j++)crc=(crc<<1)^((crc&0x80000000)?0x04c11db7:0);}return crc;
}
static void og_u32(unsigned char *p,uint32_t value){for(unsigned i=0;i<4;i++)p[i]=(unsigned char)(value>>(8*i));}
static void og_u64(unsigned char *p,uint64_t value){for(unsigned i=0;i<8;i++)p[i]=(unsigned char)(value>>(8*i));}
static unsigned og_page(const unsigned char *body,unsigned bytes,const unsigned char *laces,unsigned segments,uint64_t granule,unsigned flags){
 unsigned start=og_bytes,need=27+segments+bytes;if(segments>255||start+need>sizeof(og_file))return UINT32_MAX;
 unsigned char *p=og_file+start;memset(p,0,27);memcpy(p,"OggS",4);p[5]=(unsigned char)flags;og_u64(p+6,granule);og_u32(p+14,0x504d414c);og_u32(p+18,og_sequence++);p[26]=(unsigned char)segments;
 memcpy(p+27,laces,segments);memcpy(p+27+segments,body,bytes);og_u32(p+22,og_crc(p,need));og_bytes+=need;return start;
}
static unsigned og_packet_page(const unsigned char *data,unsigned len,uint64_t granule,unsigned flags){
 unsigned char laces[255];unsigned n=0,left=len;while(left>=255){if(n>=254)return UINT32_MAX;laces[n++]=255;left-=255;}laces[n++]=(unsigned char)left;return og_page(data,len,laces,n,granule,flags);
}
static void og_fix(void){
 for(unsigned at=0;at<og_bytes;){unsigned n=og_file[at+26],bytes=27+n;for(unsigned i=0;i<n;i++)bytes+=og_file[at+27+i];og_u32(og_file+at+22,og_crc(og_file+at,bytes));at+=bytes;}
}
static int og_headers(unsigned channels,unsigned skip,int gain,unsigned variant){
 unsigned char head[24]={0},tags[1024]={0};memcpy(head,"OpusHead",8);head[8]=(unsigned char)(variant==3?2:1);head[9]=(unsigned char)channels;head[10]=(unsigned char)skip;head[11]=(unsigned char)(skip>>8);og_u32(head+12,44100);head[16]=(unsigned char)gain;head[17]=(unsigned char)(gain>>8);
 og_bytes=og_sequence=og_audio_count=0;
 if(og_packet_page(head,variant==3?24:19,0,2)==UINT32_MAX)return 0;
 memcpy(tags,"OpusTags",8);
 if(variant==2){
  og_u32(tags+8,1008);memset(tags+12,'v',1008);unsigned char laces[]={255,255};
  if(og_page(tags,510,laces,2,UINT64_MAX,0)==UINT32_MAX||og_packet_page(tags+510,514,0,1)==UINT32_MAX)return 0;
 }else if(og_packet_page(tags,16,0,0)==UINT32_MAX)return 0;
 return 1;
}
static int og_verify(unsigned char packets[][2048],int lengths[],unsigned n,unsigned channels,unsigned skip,int gain,unsigned trim,uint64_t origin,unsigned variant){
 static float reference[1500000];unsigned raw=0;unsigned char body[65536],laces[255];
 if(!mode_reset(channels,48000)||!og_headers(channels,skip,gain,variant))return 0;
 for(unsigned i=0;i<n;i++){
  int count=opus_decode_native(mr,packets[i],lengths[i],reference+raw*channels,5760,0,0,NULL);
  if(count<=0||raw+(unsigned)count>1500000/channels)return 0;raw+=count;
 }
 if(skip>raw||trim>raw-skip)return 0;unsigned end=raw-trim,decoded=0;
 for(unsigned i=0;i<n;){
  unsigned begin=i,segments=0,bytes=0,group=variant==1?1:variant==4?n:3;
  for(;i<n&&i<begin+group;i++){
   if(bytes+(unsigned)lengths[i]>sizeof(body))return 0;
   memcpy(body+bytes,packets[i],lengths[i]);bytes+=lengths[i];unsigned left=lengths[i];
   while(left>=255){if(segments>=254)return 0;laces[segments++]=255;left-=255;}if(segments>=255)return 0;laces[segments++]=(unsigned char)left;
   int count=opus_packet_get_nb_frames(packets[i],lengths[i])*opus_packet_get_samples_per_frame(packets[i],48000);if(count<=0)return 0;decoded+=count;
  }
  uint64_t granule=origin+(i==n?end:decoded);unsigned flags=i==n?4:0;
  unsigned at;
  if(variant==5&&begin==0&&lengths[0]>=255){
   unsigned char lace=255;at=og_page(body,255,&lace,1,UINT64_MAX,0);if(at==UINT32_MAX)return 0;
   at=og_page(body+255,bytes-255,laces+1,segments-1,granule,flags|1);
  }else at=og_page(body,bytes,laces,segments,granule,flags);
  if(at==UINT32_MAX)return 0;og_audio_pages[og_audio_count++]=at;
 }
 memcpy(og_saved,og_file,og_bytes);decode_error=0;total_frames=UINT64_MAX;
 if(!opus_open(og_file,og_file+og_bytes)||decode_error||total_frames!=end-skip||sample_rate!=48000||source_channels!=channels||source_bits!=32){printf("Ogg open case%u error%u frames%llu/%u raw%u skip%u trim%u origin%llu variant%u\n",og_cases,decode_error,total_frames,end-skip,raw,skip,trim,origin,variant);return 0;}
 static struct {uint64_t before;float pcm[11520];uint64_t after;} out;
 const unsigned sizes[]={1,7,119,120,383,960,5760};unsigned emitted=0,calls=0;float factor=(float)pow(10.,gain/(20.*256.));
 memset(out.pcm,0xa5,sizeof(out.pcm));out.before=before_guard;out.after=after_guard;
 if(opus_read(out.pcm,0)||opus_read(NULL,1)||out.before!=before_guard||out.after!=after_guard)return 0;
 for(;;){
  unsigned cap=sizes[calls++%7];memset(out.pcm,0xa5,sizeof(out.pcm));int got=opus_read(out.pcm,cap);
  if(got<0||(unsigned)got>cap||decode_error||out.before!=before_guard||out.after!=after_guard||emitted+(unsigned)got>end-skip){printf("Ogg read case%u error%u got%d cap%u emitted%u frames%u\n",og_cases,decode_error,got,cap,emitted,end-skip);return 0;}
  for(unsigned i=got*2;i<11520;i++)if(memcmp(out.pcm+i,"\xa5\xa5\xa5\xa5",4))return 0;
  for(int i=0;i<got;i++)for(unsigned c=0;c<2;c++){
   float wanted=reference[(skip+emitted+i)*channels+(channels==1?0:c)]*factor,actual=out.pcm[i*2+c];float scale=fmaxf(1.f,fabsf(wanted)),error=fabsf(wanted-actual)/scale;
   if(!isfinite(actual)||error>0.00004f){printf("Ogg PCM case%u sample%u %.9g/%.9g error%.9g gain%d\n",og_cases,emitted+i,wanted,actual,error,gain);return 0;}if(error>og_max)og_max=error;og_samples++;
  }
  emitted+=got;og_checks++;if(!got)break;
 }
 if(emitted!=end-skip||memcmp(og_file,og_saved,og_bytes)||opus_read(out.pcm,1)||decode_error)return 0;
 opus_close();if(opus_read(out.pcm,1))return 0;ogg_close();og_cases++;return 1;
}
static int og_encoded(void){
 static unsigned char packets[128][2048];int lengths[128];float input[5760];
 const int bands[]={OPUS_BANDWIDTH_NARROWBAND,OPUS_BANDWIDTH_WIDEBAND,OPUS_BANDWIDTH_SUPERWIDEBAND,OPUS_BANDWIDTH_FULLBAND};
 for(unsigned config=0;config<32;config++)for(unsigned channels=1;channels<=2;channels++){
  int mode=config<12?MODE_SILK_ONLY:config<16?MODE_HYBRID:MODE_CELT_ONLY;
  int bandwidth=config<12?OPUS_BANDWIDTH_NARROWBAND+config/4:config<16?OPUS_BANDWIDTH_SUPERWIDEBAND+(config-12)/2:bands[(config-16)/4];
  unsigned char toc=(unsigned char)(config<<3);int count=opus_packet_get_samples_per_frame(&toc,48000);unsigned raw=count*8;
  OpusEncoder *enc=opus_encoder_create(48000,channels,OPUS_APPLICATION_AUDIO,NULL);if(!enc)return 0;
  opus_encoder_ctl(enc,OPUS_SET_FORCE_MODE(mode));opus_encoder_ctl(enc,OPUS_SET_BANDWIDTH(bandwidth));opus_encoder_ctl(enc,OPUS_SET_FORCE_CHANNELS(channels));opus_encoder_ctl(enc,OPUS_SET_BITRATE(mode==MODE_CELT_ONLY?128000:48000));
  for(unsigned p=0;p<8;p++){
   for(int i=0;i<count;i++)for(unsigned c=0;c<channels;c++)input[i*channels+c]=(float)(.17*sin((i+p*count)*2*3.141592653589793*(113+79*c)/48000)+(p==3?.05*sin(i*.27):0));
   lengths[p]=opus_encode_float(enc,input,count,packets[p],2048);if(lengths[p]<=0)return 0;
  }opus_encoder_destroy(enc);
  for(unsigned variant=0;variant<6;variant++){
   unsigned skip=variant==0?0:variant==4?raw/4:variant==5?raw/3:312;if(skip>=raw)skip=raw/4;
   int gain=variant==0?0:variant==1?-3072:variant==2?1536:variant==3?32767:variant==4?-32768:257;
   unsigned trim=variant==4?raw/2:variant==0?0:17;uint64_t origin=variant==1||variant==3?1234567:0;
   if(variant==5){
    const unsigned char *parts[48];short sizes[48];unsigned char toc;int offset;unsigned char padded[2048];
    int frames=opus_packet_parse(packets[0],lengths[0],&toc,parts,sizes,&offset);if(frames<1)return 0;
    unsigned pad=1000;lengths[0]=sp_build(padded,toc,parts[0],sizes[0],3,frames,0,pad);if(lengths[0]>2048)return 0;memcpy(packets[0],padded,lengths[0]);
   }
   if(!og_verify(packets,lengths,8,channels,skip,gain,trim,origin,variant))return 0;
  }
 }
 /* Pre-skip can span many packets and use every uint16 bit. */
 OpusEncoder *enc=opus_encoder_create(48000,2,OPUS_APPLICATION_AUDIO,NULL);if(!enc)return 0;
 opus_encoder_ctl(enc,OPUS_SET_FORCE_MODE(MODE_SILK_ONLY));memset(input,0,sizeof(input));
 for(unsigned p=0;p<80;p++){lengths[p]=opus_encode_float(enc,input,960,packets[p],2048);if(lengths[p]<=0)return 0;}opus_encoder_destroy(enc);
 return og_verify(packets,lengths,80,2,65535,0,13,7890123,0);
}
static int og_bad(void){
 static unsigned char base[1048576];unsigned bytes=og_bytes;memcpy(base,og_file,bytes);
 for(unsigned trial=0;trial<22;trial++){
  memcpy(og_file,base,bytes);og_bytes=bytes;unsigned first=og_audio_pages[0],later=og_audio_pages[1],last=og_audio_pages[og_audio_count-1];unsigned head=28,tags=47+28;
  switch(trial){
   case 0:og_file[head]='x';break;case 1:og_file[head+8]=16;break;case 2:og_file[head+9]=0;break;case 3:og_file[head+9]=3;break;case 4:og_file[head+18]=1;break;
   case 5:og_u64(og_file+6,1);og_u64(og_file+47+6,1);break;
   case 6:og_file[tags]='x';break;case 7:og_u32(og_file+tags+8,UINT32_MAX);break;case 8:og_u32(og_file+tags+12,UINT32_MAX);break;
   case 9:og_u64(og_file+first+6,1);break;case 10:og_u64(og_file+later+6,UINT64_MAX);break;case 11:og_u64(og_file+later+6,og_file[later+6]+1);break;
   case 12:og_u64(og_file+last+6,UINT64_C(1)<<62);break;case 13:og_u64(og_file+last+6,65534);break;
   case 14:og_file[last+5]&=~4;break;case 15:og_u32(og_file+later+18,99);break;case 16:og_u32(og_file+later+14,1);break;
   case 17:og_file[first+5]|=1;break;case 18:og_file[head+9]=2;og_file[head+18]=255;break;
   case 19:og_bytes=bytes-1;break;case 20:og_bytes=26;break;case 21:og_file[first+22]^=1;break;
  }
  if(trial<19)og_fix();decode_error=0;
  if(opus_open(og_file,og_file+og_bytes)||!decode_error){printf("Ogg invalid accepted %u\n",trial);return 0;}opus_close();ogg_close();og_rejects++;
 }
 return 1;
}
static int og_more_bounds(void){
 /* Both header packets must finish their pages. ID must fit its first page. */
 unsigned char head[600]={0},tags[16]={0},audio[]={0xf8,0xff,0xff},body[640],laces[3];
 memcpy(head,"OpusHead",8);head[8]=1;head[9]=2;head[10]=56;head[11]=1;memcpy(tags,"OpusTags",8);
 for(unsigned trial=0;trial<5;trial++){
  og_bytes=og_sequence=0;
  if(trial==0){memcpy(body,head,19);memcpy(body+19,tags,16);laces[0]=19;laces[1]=16;og_page(body,35,laces,2,0,2);}
  else if(trial==1){og_packet_page(head,19,0,2);memcpy(body,tags,16);memcpy(body+16,audio,3);laces[0]=16;laces[1]=3;og_page(body,19,laces,2,0,0);}
  else if(trial==2){head[8]=2;laces[0]=255;og_page(head,255,laces,1,UINT64_MAX,2);og_packet_page(head+255,345,0,1);og_packet_page(tags,16,0,0);head[8]=1;}
  else {og_packet_page(head,19,0,2);og_packet_page(tags,16,0,0);}
  if(trial==3)og_packet_page(audio,0,960,4);else og_packet_page(audio,3,trial==4?311:960,4);
  decode_error=0;if(opus_open(og_file,og_file+og_bytes)||!decode_error){printf("Ogg header/trim bound%u\n",trial);return 0;}opus_close();ogg_close();og_rejects++;
 }
 /* Detect a malformed entropy frame after successful structural open. */
 static float reference_pcm[11520],out[11520];unsigned char packet[64];int found=0;
 for(unsigned trial=0;trial<1024&&!found;trial++){
  packet[0]=0xf8;unsigned len=3+next()%61;for(unsigned i=1;i<len;i++)packet[i]=(unsigned char)next();
  if(!mode_reset(2,48000))return 0;mode_reference_celt_errors=0;int native=opus_decode_native(mr,packet,len,reference_pcm,5760,0,0,NULL);
  if(native>=0&&!mode_reference_celt_errors)continue;
  if(!og_headers(2,312,0,0))return 0;og_packet_page(packet,len,960,4);decode_error=0;
  if(!opus_open(og_file,og_file+og_bytes)||decode_error||opus_read(out,5760)||decode_error!=27){puts("Ogg late failure not discarded");return 0;}
  memcpy(reference_pcm,out,sizeof(out));if(opus_read(out,1)||memcmp(out,reference_pcm,sizeof(out)))return 0;opus_close();ogg_close();found=1;og_late++;
 }
 if(!found)return 0;
 /* Legal zero-byte codec frames still occupy a nonempty Ogg packet. */
 static unsigned char packets[8][2048];int lengths[8];unsigned char payload=0;
 for(unsigned channels=1;channels<=2;channels++)for(unsigned code=0;code<4;code++){
  for(unsigned p=0;p<8;p++)lengths[p]=sp_build(packets[p],0x80,&payload,p%2,code,code==3?48:1,1,0);
  if(!og_verify(packets,lengths,8,channels,23,0,7,0,4))return 0;
 }
 unsigned cancelled=1;extern unsigned *ogg_cancel_ptr;ogg_cancel_ptr=&cancelled;decode_error=0;
 if(opus_open(og_file,og_file+og_bytes)||!decode_error)return 0;og_cancel++;
 cancelled=0;decode_error=0;if(!opus_open(og_file,og_file+og_bytes))return 0;
 cancelled=1;if(opus_read(out,5760)||decode_error!=27)return 0;og_cancel++;
 ogg_cancel_ptr=NULL;opus_close();ogg_close();
 return 1;
}
static int og_external(const char *path,const char *pcm_path){
 FILE *in=fopen(path,"rb");if(!in)return 0;unsigned bytes=(unsigned)fread(og_file,1,sizeof(og_file),in);int extra=fgetc(in);fclose(in);if(extra!=EOF)return 0;
 decode_error=0;if(!opus_headers(og_file,og_file+bytes)||!mode_reset(source_channels,48000))return 0;
 static float raw[1500000],actual[1500000];unsigned count=0,packets=0;
 for(;;){const unsigned char *data=ogg_next();if(!data)break;extern unsigned ogg_packet_length;int got=opus_decode_native(mr,data,ogg_packet_length,raw+count*source_channels,5760,0,0,NULL);if(got<=0)return 0;count+=got;packets++;if(count*source_channels>1488480)return 0;}
 extern uint64_t ogg_total_granule;unsigned end=(unsigned)ogg_total_granule;if(end>count||end<op_preskip)return 0;
 in=fopen(pcm_path,"rb");if(!in)return 0;unsigned values=(unsigned)fread(actual,sizeof(float),1500000,in);extra=fgetc(in);fclose(in);if(extra!=EOF||values!=(end-op_preskip)*2)return 0;
 float maximum=0;double error=0;for(unsigned i=0;i<values;i++){float wanted=raw[(op_preskip+i/2)*source_channels+(source_channels==1?0:i%2)],diff=wanted-actual[i];maximum=fmaxf(maximum,fabsf(diff));error+=(double)diff*diff;}
 printf("External RFC PCM: %u packets,%u samples,max error%.9g,RMS%.9g\n",packets,values,maximum,sqrt(error/values));ogg_close();return maximum<=0.00004f;
}
#ifndef OPUS_OGG_ORACLE_EMBEDDED
int main(int argc,char **argv){
 if(argc==3)return og_external(argv[1],argv[2])?0:1;
 if(!og_encoded()||!og_bad()||!og_more_bounds())return 1;
 printf("Ogg Opus: %u exact reference PCM streams, mono/stereo SILK/hybrid/CELT/DTX, pre-skip0..65535, signed gain extremes, initial offsets, single/multiple audio pages, continued tags/audio, future minor header fields, end trimming, %llu stereo PCM values, %u bounded read/canary checks, %u malformed stream rejections, %u late/sticky failure checks, %u cancellation checks, max scaled error %.9g\n",og_cases,og_samples,og_checks,og_rejects,og_late,og_cancel,og_max);return 0;
}
#endif
