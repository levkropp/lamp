/* Test-only official encoder/decoder versus the assembly Ogg file bridge. */
#include "lamp-test.h"
#include <math.h>
#include "speex/speex.h"
#include "speex/speex_stereo.h"
#include "speex/speex_header.h"
#include "speex/speex_callbacks.h"
LAMP_ABI int speex_open(const void*,const void*);
LAMP_ABI unsigned speex_read(float*,unsigned);
LAMP_ABI uint64_t speex_seek(uint64_t);
LAMP_ABI void speex_close(void);
LAMP_ABI void ogg_close(void);
static unsigned deny_index,live_allocations;
LAMP_ABI void*mem_alloc(uint64_t n){if(deny_index&&n==64*(16384+32))return NULL;void*p=n<=16*1024*1024?calloc(1,(size_t)n):NULL;if(p)live_allocations++;return p;}
LAMP_ABI void mem_free(void*p){if(p)live_allocations--;free(p);}
unsigned sample_rate,source_channels,source_bits,decode_error;
uint64_t total_frames;
extern unsigned speex_index_count,ogg_select_active;
extern uint64_t speex_index_stride,speex_seek_raw;
extern unsigned*ogg_cancel_ptr;
static uint64_t checks,words,cases,seeks,cold_seeks,compactions,rejections,allocation_fallbacks,protected_prefixes,mutations,accepted_mutations;
static unsigned mode_context,quality_context,group_context,variant_context;
static unsigned char file_data[4*1024*1024];
static unsigned file_size,sequence;
static uint32_t random_seed=0x192487ab;
static uint32_t next(void){random_seed^=random_seed<<13;random_seed^=random_seed>>17;random_seed^=random_seed<<5;return random_seed;}
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"line %d mode=%u q=%u group=%u variant=%u: %s error=%u\n",__LINE__,mode_context,quality_context,group_context,variant_context,#x,decode_error);exit(1);}}while(0)
typedef struct {unsigned char*allocation,*data;size_t size;} Guard;
static Guard guarded(const void*src,size_t n){SYSTEM_INFO info;GetSystemInfo(&info);size_t page=info.dwPageSize,body=(n+page-1)/page*page;if(!body)body=page;Guard g={0};DWORD old;g.allocation=VirtualAlloc(NULL,body+page*2,MEM_RESERVE|MEM_COMMIT,PAGE_NOACCESS);CHECK(g.allocation&&VirtualProtect(g.allocation+page,body,PAGE_READWRITE,&old));g.data=g.allocation+page+body-n;g.size=n;if(n)memcpy(g.data,src,n);CHECK(VirtualProtect(g.allocation+page,body,PAGE_READONLY,&old));return g;}
static void release(Guard*g){CHECK(VirtualFree(g->allocation,0,MEM_RELEASE));}
static void exact(const float*a,const float*b,unsigned n,const char*what){for(unsigned i=0;i<n;i++){uint32_t x,y;memcpy(&x,a+i,4);memcpy(&y,b+i,4);if(x!=y){fprintf(stderr,"%s word %u reference=%a/%08x assembly=%a/%08x mode=%u q=%u group=%u variant=%u\n",what,i,(double)a[i],x,(double)b[i],y,mode_context,quality_context,group_context,variant_context);exit(1);}CHECK(x==y);}words+=n;}
static void u32(unsigned char*p,uint32_t v){for(unsigned i=0;i<4;i++)p[i]=(unsigned char)(v>>(i*8));}
static void u64(unsigned char*p,uint64_t v){for(unsigned i=0;i<8;i++)p[i]=(unsigned char)(v>>(i*8));}
static uint32_t crc(const unsigned char*p,unsigned n){uint32_t v=0;for(unsigned i=0;i<n;i++){v^=(uint32_t)(i>=22&&i<26?0:p[i])<<24;for(unsigned j=0;j<8;j++)v=(v<<1)^((v&0x80000000)?0x04c11db7:0);}return v;}
static unsigned page(const unsigned char*body,unsigned bytes,const unsigned char*laces,unsigned n,uint64_t granule,unsigned flags){CHECK(n<=255&&file_size+27+n+bytes<=sizeof(file_data));unsigned at=file_size;unsigned char*p=file_data+at;memset(p,0,27);memcpy(p,"OggS",4);p[5]=flags;u64(p+6,granule);u32(p+14,0x58504d4c);u32(p+18,sequence++);p[26]=n;memcpy(p+27,laces,n);memcpy(p+27+n,body,bytes);file_size+=27+n+bytes;u32(p+22,crc(p,27+n+bytes));return at;}
static unsigned packet_page(const unsigned char*p,unsigned n,uint64_t gp,unsigned flags){unsigned char laces[255];unsigned count=0,left=n;while(left>=255){CHECK(count<254);laces[count++]=255;left-=255;}laces[count++]=left;return page(p,n,laces,count,gp,flags);}
typedef struct {unsigned char*data;unsigned bytes;} Packet;
static void headers(unsigned mode,unsigned channels,unsigned group,unsigned rate,unsigned extra,unsigned variant){
 const SpeexMode*modes[]={&speex_nb_mode,&speex_wb_mode,&speex_uwb_mode};SpeexHeader h;speex_init_header(&h,rate,channels,modes[mode]);h.frames_per_packet=group;h.extra_headers=extra;int bytes;char*p=speex_header_to_packet(&h,&bytes);CHECK(p&&bytes>=80);file_size=sequence=0;packet_page((unsigned char*)p,bytes,0,2);speex_header_free(p);unsigned char comment[1400]={0};unsigned vendor=variant==2?1100:4;u32(comment,vendor);memset(comment+4,'v',vendor);u32(comment+4+vendor,1);u32(comment+8+vendor,17);memcpy(comment+12+vendor,"TITLE=Speex test!!",17);unsigned size=vendor+29;
 if(variant==2){unsigned char lace=255;page(comment,255,&lace,1,UINT64_MAX,0);packet_page(comment+255,size-255,0,1);}else packet_page(comment,size,0,0);
 for(unsigned i=0;i<extra;i++){unsigned char data[19]={0};data[0]=i;packet_page(data,sizeof(data),0,0);}
}
static void fix_crcs(void){for(unsigned at=0;at<file_size;){unsigned n=file_data[at+26],bytes=27+n;for(unsigned i=0;i<n;i++)bytes+=file_data[at+27+i];u32(file_data+at+22,crc(file_data+at,bytes));at+=bytes;}}
static void close_clean(void){speex_close();ogg_close();CHECK(!speex_index_count&&!live_allocations);float f[2];CHECK(!speex_read(f,1));}
static unsigned read_and_compare(const float*expected,unsigned frames,unsigned chunks){float out[8194];unsigned pos=0;while(pos<frames){unsigned want=1+next()%chunks;if(want>4096)want=4096;memset(out,0xa5,sizeof(out));unsigned n=speex_read(out,want);CHECK(!decode_error&&n&&n<=want&&n<=frames-pos);exact(expected+pos*2,out,n*2,"continuous PCM");for(unsigned j=n*8;j<sizeof(out);j++)CHECK(((unsigned char*)out)[j]==0xa5);pos+=n;}CHECK(!speex_read(out,4096)&&!decode_error);return pos;}
static void discard(uint64_t base,uint64_t target){float out[8192];while(base<target){unsigned want=target-base>4096?4096:(unsigned)(target-base);CHECK(speex_read(out,want)==want&&!decode_error);base+=want;}}
static void verify(const float*raw,unsigned raw_frames,unsigned skip,unsigned tail,unsigned rate,unsigned channels,unsigned packets){
 CHECK(skip+tail<=raw_frames);unsigned frames=raw_frames-skip-tail;const float*expected=raw+skip*2;Guard source=guarded(file_data,file_size);decode_error=0;ogg_select_active=0;CHECK(speex_open(source.data,source.data+file_size)&&!decode_error&&sample_rate==rate&&source_channels==channels&&source_bits==0&&total_frames==frames);read_and_compare(expected,frames,4089);CHECK(speex_index_count>=1&&speex_index_count<=64);if(packets>1024){CHECK(speex_index_stride>=32);compactions++;}
 for(unsigned i=0;i<32;i++){uint64_t target=i==0?0:i==1?frames:i==2?frames/2:i==3?frames-1:next()%(frames+1);uint64_t base=speex_seek(target);CHECK(!decode_error&&base<=target);if(i==2&&packets>32)CHECK(base>0);discard(base,target);float out[514];memset(out,0xa5,sizeof(out));unsigned want=257,n=speex_read(out,want),expected_n=frames-target<want?(unsigned)(frames-target):want;CHECK(!decode_error&&n==expected_n);exact(expected+target*2,out,n*2,"warm seek PCM");seeks++;}
 close_clean();decode_error=0;CHECK(speex_open(source.data,source.data+file_size));uint64_t target=frames*3/4,base=speex_seek(target);CHECK(!decode_error&&base<=target);discard(base,target);float out[256];unsigned n=speex_read(out,128),want=frames-target<128?(unsigned)(frames-target):128;CHECK(n==want&&!decode_error);exact(expected+target*2,out,n*2,"cold seek PCM");cold_seeks++;close_clean();release(&source);cases++;
}
static void encoded_case(unsigned mode,unsigned channels,unsigned quality,unsigned group,unsigned variant,unsigned count,uint64_t origin,unsigned extra){
 mode_context=mode;quality_context=quality;group_context=group;variant_context=variant;const SpeexMode*modes[]={&speex_nb_mode,&speex_wb_mode,&speex_uwb_mode};unsigned n=160u<<mode,rate=variant==5?11025:8000u<<mode,raw_frames=((variant==8?(count-1)*group+1:count*group))*n;float*raw=malloc((size_t)raw_frames*8);Packet*packets=calloc(count,sizeof(*packets));void*enc=speex_encoder_init(modes[mode]),*dec=speex_decoder_init(modes[mode]);CHECK(raw&&packets&&enc&&dec);int q=quality;CHECK(!speex_encoder_ctl(enc,SPEEX_SET_QUALITY,&q));int on=variant==1;CHECK(!speex_encoder_ctl(enc,SPEEX_SET_VBR,&on));CHECK(!speex_encoder_ctl(enc,SPEEX_SET_VAD,&on));CHECK(!speex_encoder_ctl(enc,SPEEX_SET_DTX,&on));SpeexStereoState st;speex_stereo_state_reset(&st);if(channels==2){SpeexCallback cb={SPEEX_INBAND_STEREO,speex_std_stereo_request_handler,&st};CHECK(!speex_decoder_ctl(dec,SPEEX_SET_HANDLER,&cb));}unsigned raw_pos=0;
 for(unsigned packet=0;packet<count;packet++){unsigned frame_count=variant==8&&packet+1==count?1:group;SpeexBits b;speex_bits_init(&b);for(unsigned j=0;j<frame_count;j++){float input[1280];unsigned frame=packet*group+j;for(unsigned i=0;i<n;i++){double t=(frame*n+i)/(double)rate;float x=frame%61<16?0.f:(float)(8000*sin(6.283185307179586*337*t));if(frame%61>40)x=((int)(next()%24001)-12000)*.5f;if(channels==1)input[i]=x;else{input[i*2]=x*(frame%5)*.3f;input[i*2+1]=(float)(.7*x+1000*sin(6.283185307179586*911*t));}}if(channels==2)speex_encode_stereo(input,n,&b);CHECK(speex_encode(enc,input,&b)>=0);}unsigned bytes=speex_bits_nbytes(&b);packets[packet].data=malloc(bytes);CHECK(packets[packet].data);packets[packet].bytes=speex_bits_write(&b,(char*)packets[packet].data,bytes);speex_bits_read_from(&b,(char*)packets[packet].data,packets[packet].bytes);for(unsigned j=0;j<frame_count;j++){float output[1280];CHECK(!speex_decode(dec,&b,output));if(channels==2)speex_decode_stereo(output,n,&st);for(unsigned i=0;i<n;i++){raw[(raw_pos+i)*2]=output[i*channels]*(1.f/32768);raw[(raw_pos+i)*2+1]=output[i*channels+(channels==2)]*(1.f/32768);}raw_pos+=n;}speex_bits_destroy(&b);}
 unsigned encoder_delay=40;for(unsigned i=0;i<mode;i++)encoder_delay=encoder_delay*2+63;unsigned skip=(origin?0:encoder_delay)+(40u<<mode);if(variant==4){encoder_delay+=n*2;skip+=n*2;}unsigned tail=variant==6?raw_frames-skip-1:raw_frames>skip+83?83:0;headers(mode,channels,group,rate,extra,variant);unsigned completed=0;
 for(unsigned i=0;i<count;){unsigned begin=i,bytes=0,segments=0;unsigned char body[65536],laces[255];unsigned page_packets=variant==3?count:variant==2?1:3;for(;i<count&&i<begin+page_packets;i++){CHECK(bytes+packets[i].bytes<=sizeof(body));memcpy(body+bytes,packets[i].data,packets[i].bytes);bytes+=packets[i].bytes;unsigned left=packets[i].bytes;while(left>=255){CHECK(segments<254);laces[segments++]=255;left-=255;}CHECK(segments<255);laces[segments++]=left;completed+=(variant==8&&i+1==count?1:group)*n;}uint64_t gp=i==count?origin+raw_frames-skip-tail:origin?origin+completed:completed-encoder_delay;unsigned flags=i==count?4:0;if(variant==2&&bytes>255){unsigned char first=255;page(body,255,&first,1,UINT64_MAX,0);CHECK(segments>=2&&laces[0]==255);page(body+255,bytes-255,laces+1,segments-1,gp,flags|1);}else page(body,bytes,laces,segments,gp,flags);}
 verify(raw,raw_frames,skip,tail,rate,channels,count);
 /* Save current valid fixture for malformed checks in main. */
 for(unsigned i=0;i<count;i++)free(packets[i].data);free(packets);free(raw);speex_encoder_destroy(enc);speex_decoder_destroy(dec);
}
static void rejected(void){
 unsigned bytes=file_size,offsets[16],page_count=0;unsigned char*saved=malloc(bytes);CHECK(saved);memcpy(saved,file_data,bytes);
 for(unsigned at=0;at<bytes;){CHECK(page_count<16);offsets[page_count++]=at;unsigned n=file_data[at+26],size=27+n;for(unsigned i=0;i<n;i++)size+=file_data[at+27+i];at+=size;}CHECK(page_count>=5);
 for(unsigned variant=0;variant<12;variant++){
  variant_context=100+variant;memcpy(file_data,saved,bytes);file_size=bytes;
  switch(variant){case 0:file_data[22]^=1;break;case 1:file_data[5]|=4;break;case 2:u32(file_data+28+32,1);break;case 3:u32(file_data+28+64,65);break;case 4:u32(file_data+28+48,3);break;case 5:file_size=bytes-1;break;case 6:u32(file_data+28+36,0);break;case 7:u32(file_data+28+68,65);break;case 8:u64(file_data+offsets[2]+6,447);break;case 9:u64(file_data+offsets[page_count-1]+6,1000000);break;case 10:{unsigned at=offsets[2],body=at+27+file_data[at+26];file_data[body]=(file_data[body]&7)|0x48;break;}case 11:{unsigned at=offsets[1],body=at+27+file_data[at+26];u32(file_data+body,0xffffffff);break;}}
  if(variant!=0&&variant!=5)fix_crcs();decode_error=0;CHECK(!speex_open(file_data,file_data+file_size)&&decode_error);close_clean();rejections++;
 }
 memcpy(file_data,saved,bytes);file_size=bytes;free(saved);unsigned cancel=1;ogg_cancel_ptr=&cancel;decode_error=0;CHECK(!speex_open(file_data,file_data+bytes)&&decode_error);ogg_cancel_ptr=NULL;close_clean();decode_error=0;CHECK(speex_open(file_data,file_data+bytes));ogg_cancel_ptr=&cancel;float output[2];CHECK(!speex_read(output,1)&&decode_error);ogg_cancel_ptr=NULL;close_clean();rejections+=2;
}
static void allocation_fallback(void){
 decode_error=0;CHECK(speex_open(file_data,file_data+file_size));unsigned frames=(unsigned)total_frames;float*expected=malloc((size_t)frames*8);CHECK(expected&&speex_read(expected,frames)==frames&&!decode_error);close_clean();deny_index=1;decode_error=0;CHECK(speex_open(file_data,file_data+file_size)&&!speex_index_count);unsigned target=frames/2;CHECK(!speex_seek(target));discard(0,target);float output[256];unsigned n=speex_read(output,128),want=frames-target<128?frames-target:128;CHECK(n==want&&!decode_error);exact(expected+target*2,output,n*2,"allocation fallback seek");close_clean();deny_index=0;free(expected);allocation_fallbacks++;
}
static void bounded_mutations(void){
 unsigned bytes=file_size;unsigned char*saved=malloc(bytes);CHECK(saved);memcpy(saved,file_data,bytes);
 for(unsigned n=0;n<bytes;n++){Guard source=guarded(saved,n);decode_error=0;CHECK(!speex_open(source.data,source.data+n)&&decode_error);close_clean();release(&source);protected_prefixes++;}
 for(unsigned i=0;i<1024;i++){memcpy(file_data,saved,bytes);unsigned at=next()%bytes;file_data[at]^=1u<<(next()%8);/* Repair CRCs only when all page extents remain parseable. */
  unsigned pos=0;int structure=1;while(pos<bytes){if(bytes-pos<27||memcmp(file_data+pos,"OggS",4)){structure=0;break;}unsigned ns=file_data[pos+26];if(pos+27+ns>bytes){structure=0;break;}unsigned size=27+ns;for(unsigned j=0;j<ns;j++)size+=file_data[pos+27+j];if(pos+size>bytes){structure=0;break;}u32(file_data+pos+22,crc(file_data+pos,size));pos+=size;}if(pos!=bytes)structure=0;
  Guard source=guarded(file_data,bytes);decode_error=0;int opened=speex_open(source.data,source.data+bytes);if(opened){float out[8194];uint64_t total=0;for(unsigned calls=0;;calls++){CHECK(calls<100&&total<=8192);memset(out,0xa5,sizeof(out));unsigned n=speex_read(out,4096);CHECK(n<=4096);for(unsigned j=n*8;j<sizeof(out);j++)CHECK(((unsigned char*)out)[j]==0xa5);for(unsigned j=0;j<n*2;j++)CHECK(isfinite(out[j]));total+=n;if(!n)break;}if(!decode_error)accepted_mutations++;}else CHECK(decode_error);close_clean();release(&source);mutations++;(void)structure;
 }memcpy(file_data,saved,bytes);free(saved);
}
int main(void){const unsigned groups[]={1,2,5,64};for(unsigned mode=0;mode<3;mode++)for(unsigned channels=1;channels<=2;channels++)for(unsigned q=0;q<=10;q++)encoded_case(mode,channels,q,groups[q%4],q%2,groups[q%4]==64?3:11,0,0);for(unsigned mode=0;mode<3;mode++)for(unsigned v=2;v<=5;v++)encoded_case(mode,2,7,v==2?64:2,v,v==3?2:9,v==5?50000:0,2);for(unsigned mode=0;mode<3;mode++){encoded_case(mode,2,5,1,6,1,0,0);encoded_case(mode,2,5,5,8,4,0,0);}encoded_case(0,2,5,1,0,1152,0,0);encoded_case(0,2,5,1,0,11,0,0);rejected();allocation_fallback();bounded_mutations();printf("{\"suite\":\"speex-files\",\"checks\":%llu,\"exact_float_words\":%llu,\"files\":%llu,\"warm_seeks\":%llu,\"cold_seeks\":%llu,\"cache_compactions\":%llu,\"allocation_fallbacks\":%llu,\"protected_prefixes\":%llu,\"mutations\":%llu,\"accepted_mutations\":%llu,\"rejections\":%llu}\n",(unsigned long long)checks,(unsigned long long)words,(unsigned long long)cases,(unsigned long long)seeks,(unsigned long long)cold_seeks,(unsigned long long)compactions,(unsigned long long)allocation_fallbacks,(unsigned long long)protected_prefixes,(unsigned long long)mutations,(unsigned long long)accepted_mutations,(unsigned long long)rejections);return 0;}
