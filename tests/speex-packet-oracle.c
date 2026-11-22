/* Test-only Speex framing/bit-access oracle. Official reference C is never
   linked into the player. See THIRD_PARTY_NOTICES for the pinned BSD source. */
#include "lamp-test.h"
#include <math.h>
#include "speex/speex.h"
#include "speex/speex_bits.h"
#include "speex/speex_header.h"
#include "speex/speex_stereo.h"
#include "quant_lsp.h"
typedef struct {const unsigned char*data;uint32_t bits,pos,error,reserved;} Bits;
typedef struct {uint32_t frames,samples,coded_bits,controls,wb,uwb,stereo,reserved;} Packet;
typedef struct {uint32_t rate,mode,channels,frame,fpp,extra,vbr;int32_t bitrate;} Header;
LAMP_ABI int spx_bits_init(Bits*,const void*,unsigned);
LAMP_ABI unsigned spx_bits_read(Bits*,unsigned);
LAMP_ABI unsigned spx_bits_peek(Bits*,unsigned);
LAMP_ABI int spx_bits_advance(Bits*,unsigned);
LAMP_ABI int spx_bits_remaining(Bits*);
LAMP_ABI int spx_header_parse(const void*,unsigned,Header*);
LAMP_ABI int spx_packet_scan(const void*,unsigned,unsigned,Packet*);
LAMP_ABI unsigned spx_lsp_unquant(Bits*,float*,unsigned,unsigned);
static uint32_t rng=0x19577291;
static uint32_t next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static uint64_t checks,bit_checks,header_checks,packets,prefixes,mutations,accepted_mutations,controls;
static unsigned nb_mask,wb_mask,uwb_mask;
static uint64_t lsp_cases,lsp_words,lsp_truncated;
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"line %d: %s\n",__LINE__,#x);exit(1);}}while(0)
typedef struct {unsigned char*allocation,*data;size_t size;} Guard;
static Guard guarded(size_t n){
 SYSTEM_INFO info;GetSystemInfo(&info);size_t page=info.dwPageSize,body=(n+page-1)/page*page;if(!body)body=page;
 Guard g={0};DWORD old;g.allocation=VirtualAlloc(NULL,body+page*2,MEM_RESERVE|MEM_COMMIT,PAGE_NOACCESS);CHECK(g.allocation&&VirtualProtect(g.allocation+page,body,PAGE_READWRITE,&old));g.data=g.allocation+page+body-n;g.size=n;return g;
}
static void release(Guard*g){CHECK(VirtualFree(g->allocation,0,MEM_RELEASE));}
static int inspect(const unsigned char*p,unsigned n,unsigned mode,Packet*out){
 Guard input=guarded(n),output=guarded(sizeof(Packet)+32);if(n)memcpy(input.data,p,n);memset(output.data,0xa5,output.size);
 int count=spx_packet_scan(input.data,n,mode,(Packet*)(output.data+32));
 for(unsigned j=0;j<32;j++)CHECK(output.data[j]==0xa5);
 if(count<0){for(size_t j=32;j<output.size;j++)CHECK(output.data[j]==0xa5);}
 else {Packet*found=(Packet*)(output.data+32);CHECK(count>0&&count<=64&&found->frames==(unsigned)count&&found->samples==found->frames*(160u<<mode)&&found->reserved==0&&found->coded_bits<=n*8&&found->controls<=1024&&found->stereo<=found->controls&&found->uwb<=found->wb&&found->wb<=found->frames);if(out)*out=*found;}
 release(&input);release(&output);return count;
}
static void bit_access(void){
 for(unsigned trial=0;trial<4096;trial++){
  unsigned n=next()%257;Guard input=guarded(n);for(unsigned j=0;j<n;j++)input.data[j]=(unsigned char)next();Bits ours;SpeexBits ref;CHECK(spx_bits_init(&ours,input.data,n));speex_bits_set_bit_buffer(&ref,input.data,n);
  /* Also exercise a final byte with only some valid bits. */
  if(n){unsigned remove=next()%8;ours.bits-=remove;ref.nbBits-=remove;}
  for(unsigned op=0;op<64;op++){
   unsigned kind=next()%3,width=next()%33,a,b;
   if(kind==0){a=spx_bits_read(&ours,width);b=speex_bits_unpack_unsigned(&ref,width);CHECK(a==b);}
   else if(kind==1){a=spx_bits_peek(&ours,width);b=speex_bits_peek_unsigned(&ref,width);CHECK(a==b);}
   else {a=spx_bits_advance(&ours,width);speex_bits_advance(&ref,width);CHECK(a==(unsigned)!ref.overflow);}
   CHECK(ours.pos==(unsigned)(ref.charPtr*8+ref.bitPtr)&&ours.error==(unsigned)!!ref.overflow&&spx_bits_remaining(&ours)==speex_bits_remaining(&ref));bit_checks++;
  }
  release(&input);
 }
 Bits state;CHECK(!spx_bits_init(NULL,NULL,0));CHECK(!spx_bits_init(&state,NULL,1)&&state.error&&state.pos==0);CHECK(!spx_bits_init(&state,(void*)(UINTPTR_MAX-3),8));CHECK(!spx_bits_init(&state,(void*)1,1048577));CHECK(spx_bits_init(&state,NULL,0));CHECK(!spx_bits_read(&state,33)&&state.error&&!state.pos);CHECK(spx_bits_init(&state,NULL,0));CHECK(!spx_bits_advance(&state,UINT32_MAX)&&state.error);CHECK(spx_bits_remaining(NULL)==-1);
}
static int header(const unsigned char*p,unsigned n,Header*out){
 Guard input=guarded(n),output=guarded(sizeof(Header)+32);if(n)memcpy(input.data,p,n);memset(output.data,0xa5,output.size);int valid=spx_header_parse(input.data,n,(Header*)(output.data+32));
 for(unsigned j=0;j<32;j++)CHECK(output.data[j]==0xa5);if(!valid){for(size_t j=32;j<output.size;j++)CHECK(output.data[j]==0xa5);}else if(out)*out=*(Header*)(output.data+32);header_checks++;release(&input);release(&output);return valid;
}
static void headers(void){
 for(int mode=0;mode<3;mode++)for(int channels=1;channels<=2;channels++)for(int fpp=0;fpp<=64;fpp++){
  SpeexHeader h;speex_init_header(&h,8000<<mode,channels,speex_lib_get_mode(mode));h.frames_per_packet=fpp;h.extra_headers=fpp;h.vbr=fpp&1;int n;char*data=speex_header_to_packet(&h,&n);Header result;CHECK(header((unsigned char*)data,n,&result));CHECK(result.rate==(unsigned)h.rate&&result.mode==(unsigned)mode&&result.channels==(unsigned)channels&&result.frame==(160u<<mode)&&result.fpp==(unsigned)(fpp?fpp:1)&&result.extra==(unsigned)fpp&&result.vbr==(unsigned)h.vbr&&result.bitrate==-1);
  if(fpp==0){for(int prefix=0;prefix<n;prefix++)CHECK(!header((unsigned char*)data,prefix,NULL));}
  if(mode==0&&channels==1&&fpp==1){
   for(unsigned offset=28;offset<=68;offset+=4){unsigned char bad[80];memcpy(bad,data,80);memset(bad+offset,0xff,4);if(offset!=52)CHECK(!header(bad,80,NULL));}
   unsigned char extra[96];memcpy(extra,data,80);memset(extra+80,0,16);extra[32]=96;CHECK(header(extra,96,&result));extra[32]=97;CHECK(!header(extra,96,NULL));
   unsigned char bad[80];memcpy(bad,data,80);bad[0]^=1;CHECK(!header(bad,80,NULL));memcpy(bad,data,80);CHECK(!spx_header_parse(bad,80,(Header*)(bad+1)));CHECK(!spx_header_parse(NULL,80,&result));CHECK(!spx_header_parse(bad,80,NULL));CHECK(!spx_header_parse((void*)(UINTPTR_MAX-7),80,&result));
  }
  speex_header_free(data);
 }
}
static unsigned reference_used(const SpeexBits*b){return(unsigned)(b->charPtr*8+b->bitPtr);}
static void count_submodes(const unsigned char*p,unsigned n){
 /* Identify actual modes through official bit primitives and mode queries.
    The sample count and final consumed offset below come from full decode. */
 SpeexBits bits;speex_bits_set_bit_buffer(&bits,(void*)p,n);unsigned layer=0;
 while(speex_bits_remaining(&bits)>=5){
  unsigned high=speex_bits_unpack_unsigned(&bits,1),mode=speex_bits_unpack_unsigned(&bits,high?3:4);int amount=mode;
  if(high){if(mode>4)break;if(layer++)uwb_mask|=1u<<mode;else wb_mask|=1u<<mode;speex_mode_query(&speex_wb_mode,SPEEX_SUBMODE_BITS_PER_FRAME,&amount);speex_bits_advance(&bits,amount-4);continue;}
  if(mode>8)break;layer=0;nb_mask|=1u<<mode;speex_mode_query(&speex_nb_mode,SPEEX_SUBMODE_BITS_PER_FRAME,&amount);speex_bits_advance(&bits,amount-5);
 }
}
static void encoded(void){
 unsigned fpps[]={1,2,5,64};
 for(int mode=0;mode<3;mode++)for(int quality=0;quality<=10;quality++)for(int stereo=0;stereo<2;stereo++)for(unsigned grouping=0;grouping<4;grouping++)for(int policy=0;policy<3;policy++){
  const SpeexMode*m=speex_lib_get_mode(mode);void*encoder=speex_encoder_init(m),*decoder=speex_decoder_init(m);CHECK(encoder&&decoder);int complexity=1;CHECK(!speex_encoder_ctl(encoder,SPEEX_SET_QUALITY,&quality));CHECK(!speex_encoder_ctl(encoder,SPEEX_SET_COMPLEXITY,&complexity));int enabled=1;if(policy==1)CHECK(!speex_encoder_ctl(encoder,SPEEX_SET_VBR,&enabled));if(policy==2){CHECK(!speex_encoder_ctl(encoder,SPEEX_SET_VAD,&enabled));CHECK(!speex_encoder_ctl(encoder,SPEEX_SET_DTX,&enabled));}
  SpeexBits bits;speex_bits_init(&bits);float source[1280],pcm[640];unsigned frames=fpps[grouping],frame_size=160u<<mode;
  for(unsigned frame=0;frame<frames;frame++){
   for(unsigned i=0;i<frame_size*(stereo+1);i++)source[i]=(policy==2&&frame>7)?0.f:(float)(1800.*sin((frame*frame_size+i)*.087)+(int)(next()%400)-200);
   if(stereo)speex_encode_stereo(source,frame_size,&bits);
   CHECK(speex_encode(encoder,source,&bits)>=0);
  }
  unsigned coded=bits.nbBits;unsigned char data[16384];int n=speex_bits_write(&bits,(char*)data,sizeof(data));CHECK(n>0&&n<(int)sizeof(data));Packet found;
  for(unsigned projected=0;projected<3;projected++){int result=inspect(data,n,projected,&found);if(result!=(int)frames){fprintf(stderr,"encode mode=%d quality=%d stereo=%d group=%u policy=%d bytes=%d expected=%u got=%d\n",mode,quality,stereo,grouping,policy,n,frames,result);exit(1);}CHECK(found.coded_bits==coded&&found.controls==(unsigned)(stereo?frames:0)&&found.stereo==found.controls);}
  count_submodes(data,n);
  SpeexBits input;speex_bits_set_bit_buffer(&input,data,n);for(unsigned frame=0;frame<frames;frame++)CHECK(!speex_decode(decoder,&input,pcm));CHECK(reference_used(&input)==coded&&!input.overflow);packets++;
  if(quality==5&&grouping==2&&policy==0&&!stereo){for(unsigned prefix=0;prefix<(unsigned)n;prefix++){inspect(data,prefix,mode,NULL);prefixes++;}}
  if(mode==0&&quality==5&&grouping==2&&policy==0&&!stereo){for(unsigned i=0;i<4096;i++){unsigned char altered[16384];memcpy(altered,data,n);unsigned edits=1+next()%4;for(unsigned j=0;j<edits;j++)altered[next()%n]^=(unsigned char)(1u<<(next()%8));if(inspect(altered,n,mode,NULL)>0)accepted_mutations++;mutations++;}}
  speex_bits_destroy(&bits);speex_encoder_destroy(encoder);speex_decoder_destroy(decoder);
 }
}
static void control_packets(void){
 for(unsigned id=0;id<16;id++)for(unsigned user=0;user<16;user++){
  SpeexBits bits;speex_bits_init(&bits);unsigned width=id<2?1:id<8?4:id<10?8:id<12?16:id<14?32:64;
  speex_bits_pack(&bits,14,5);speex_bits_pack(&bits,id,4);for(unsigned j=0;j<width;j++)speex_bits_pack(&bits,next()&1,1);
  speex_bits_pack(&bits,13,5);speex_bits_pack(&bits,user,4);for(unsigned j=0;j<5+user*8;j++)speex_bits_pack(&bits,next()&1,1);
  speex_bits_pack(&bits,0,5);unsigned coded=bits.nbBits;unsigned char data[64];int n=speex_bits_write(&bits,(char*)data,sizeof(data));Packet p;CHECK(inspect(data,n,0,&p)==1);CHECK(p.coded_bits==coded&&p.controls==2&&p.stereo==(unsigned)(id==9));controls++;
  void*decoder=speex_decoder_init(&speex_nb_mode);SpeexBits input;speex_bits_set_bit_buffer(&input,data,n);float pcm[160];CHECK(!speex_decode(decoder,&input,pcm)&&reference_used(&input)==coded&&!input.overflow);speex_decoder_destroy(decoder);speex_bits_destroy(&bits);
 }
 /* Null higher layers can occupy exactly the final four bits. */
 for(unsigned layers=0;layers<=2;layers++)for(unsigned frames=1;frames<=64;frames++){
  SpeexBits bits;speex_bits_init(&bits);for(unsigned frame=0;frame<frames;frame++){speex_bits_pack(&bits,0,5);for(unsigned layer=0;layer<layers;layer++)speex_bits_pack(&bits,8,4);}unsigned coded=bits.nbBits;unsigned char data[128];int n=speex_bits_write(&bits,(char*)data,sizeof(data));Packet p;CHECK(inspect(data,n,2,&p)==(int)frames&&p.coded_bits==coded&&p.wb==(layers?frames:0)&&p.uwb==(layers==2?frames:0));
  SpeexBits input;speex_bits_set_bit_buffer(&input,data,n);void*decoder=speex_decoder_init(speex_lib_get_mode(layers));float pcm[640];for(unsigned frame=0;frame<frames;frame++)CHECK(!speex_decode(decoder,&input,pcm));CHECK(reference_used(&input)==coded&&!input.overflow);speex_decoder_destroy(decoder);if(layers==2)uwb_mask|=1;controls++;speex_bits_destroy(&bits);
 }
 /* Resource caps, invalid modes/layers, explicit terminators and bad pad. */
 SpeexBits bits;speex_bits_init(&bits);for(unsigned f=0;f<65;f++)speex_bits_pack(&bits,0,5);unsigned char data[2048];int n=speex_bits_write(&bits,(char*)data,sizeof(data));CHECK(inspect(data,n,0,NULL)==-1);speex_bits_reset(&bits);
 for(unsigned i=0;i<1025;i++){speex_bits_pack(&bits,14,5);speex_bits_pack(&bits,0,4);speex_bits_pack(&bits,0,1);}speex_bits_pack(&bits,0,5);n=speex_bits_write(&bits,(char*)data,sizeof(data));CHECK(inspect(data,n,0,NULL)==-1);speex_bits_reset(&bits);
 speex_bits_pack(&bits,0,5);speex_bits_pack(&bits,15,5);n=speex_bits_write(&bits,(char*)data,sizeof(data));Packet p;CHECK(inspect(data,n,0,&p)==1&&p.coded_bits==5);data[n++]=0;CHECK(inspect(data,n,0,NULL)==-1);
 for(unsigned mode=9;mode<13;mode++){speex_bits_reset(&bits);speex_bits_pack(&bits,mode,5);n=speex_bits_write(&bits,(char*)data,sizeof(data));CHECK(inspect(data,n,0,NULL)==-1);}
 unsigned char bad[]={0,0xff,0x07,0x03};CHECK(inspect(bad,1,0,NULL)==-1);CHECK(inspect(bad+1,1,0,NULL)==-1);CHECK(inspect(bad+2,1,0,NULL)==-1);CHECK(inspect(bad+3,1,0,&p)==1);
 Packet untouched;memset(&untouched,0xa5,sizeof(untouched));CHECK(spx_packet_scan(NULL,1,0,&untouched)==-1);CHECK(spx_packet_scan(data,1,3,&untouched)==-1);CHECK(spx_packet_scan(data,1,0,NULL)==-1);CHECK(spx_packet_scan(data,1048577,0,&untouched)==-1);CHECK(spx_packet_scan((void*)(UINTPTR_MAX-2),10,0,&untouched)==-1);CHECK(spx_packet_scan(data,1,0,(Packet*)data)==-1);
 speex_bits_destroy(&bits);
}
static void spectral_books(void){
 for(unsigned kind=0;kind<3;kind++){
  unsigned stages=kind==0?5:kind==1?3:2,count=kind==2?8:10,required=stages*6;
  Guard input=guarded(8),output=guarded(count*4+32);SpeexBits writer;speex_bits_init(&writer);
  unsigned cases=kind==0?86016:kind==1?262144:4096;
  for(unsigned trial=0;trial<cases;trial++){
   unsigned offset=trial%8,indices[5];for(unsigned j=0;j<stages;j++)indices[j]=next()%64;
   if(kind==1){indices[0]=trial&63;indices[1]=(trial>>6)&63;indices[2]=(trial>>12)&63;}
   if(kind==2){indices[0]=trial&63;indices[1]=(trial>>6)&63;}
   if(kind==0&&trial<20480){unsigned pair=trial/4096;indices[pair]=trial&63;indices[(pair+1)%stages]=(trial>>6)&63;}
   speex_bits_reset(&writer);speex_bits_pack(&writer,0,offset);for(unsigned j=0;j<stages;j++)speex_bits_pack(&writer,indices[j],6);
   unsigned char packed[8];unsigned n=speex_bits_write(&writer,(char*)packed,sizeof(packed));unsigned char*data=input.data+8-n;memcpy(data,packed,n);
   Bits ours;CHECK(spx_bits_init(&ours,data,n));ours.bits=offset+required;CHECK(spx_bits_advance(&ours,offset));SpeexBits reference;speex_bits_set_bit_buffer(&reference,data,n);reference.nbBits=offset+required;speex_bits_advance(&reference,offset);float expected[10];
   if(kind==0)lsp_unquant_nb(expected,count,&reference);else if(kind==1)lsp_unquant_lbr(expected,count,&reference);else lsp_unquant_high(expected,count,&reference);
   memset(output.data,0xa5,output.size);unsigned got=spx_lsp_unquant(&ours,(float*)(output.data+32),kind,count);CHECK(got==count&&ours.pos==reference_used(&reference)&&!ours.error&&!reference.overflow);CHECK(!memcmp(output.data+32,expected,count*4));for(unsigned j=0;j<32;j++)CHECK(output.data[j]==0xa5);lsp_cases++;lsp_words+=count;
  }
  for(unsigned offset=0;offset<8;offset++)for(unsigned available=0;available<required;available++){
   memset(input.data,0xff,input.size);Bits state;CHECK(spx_bits_init(&state,input.data,8));state.bits=offset+available;state.pos=offset;memset(output.data,0xa5,output.size);CHECK(!spx_lsp_unquant(&state,(float*)(output.data+32),kind,count)&&state.error&&state.pos==offset);for(size_t j=0;j<output.size;j++)CHECK(output.data[j]==0xa5);lsp_truncated++;
  }
  Bits state;CHECK(spx_bits_init(&state,input.data,8));float result[10];memset(result,0xa5,sizeof(result));CHECK(!spx_lsp_unquant(&state,result,kind,count-1)&&!state.error&&!state.pos);CHECK(!spx_lsp_unquant(&state,(float*)input.data,kind,count)&&!state.pos);CHECK(!spx_lsp_unquant(&state,(float*)&state,kind,count)&&!state.pos);CHECK(!spx_lsp_unquant(&state,(float*)(UINTPTR_MAX-7),kind,count)&&!state.pos);CHECK(!spx_lsp_unquant(NULL,result,kind,count));CHECK(!spx_lsp_unquant(&state,NULL,kind,count));CHECK(!spx_lsp_unquant(&state,result,3,count));
  speex_bits_destroy(&writer);release(&input);release(&output);
 }
}
int lamp_main(int argc,lamp_char**argv){
 (void)argc;(void)argv;bit_access();headers();encoded();control_packets();spectral_books();
 CHECK(nb_mask==0x1ff);CHECK(wb_mask==31);CHECK(uwb_mask==3);
 printf("{\"result\":\"passed\",\"checks\":%llu,\"bit_operations\":%llu,\"header_cases\":%llu,\"encoded_packets\":%llu,\"projected_output_modes\":3,\"protected_prefixes\":%llu,\"mutations\":%llu,\"structurally_accepted_mutations\":%llu,\"control_and_null_layer_packets\":%llu,\"narrowband_submode_mask\":%u,\"wideband_submode_mask\":%u,\"ultrawideband_coverage\":%u,\"lsp_cases\":%llu,\"lsp_float_words\":%llu,\"lsp_truncated_inputs\":%llu,\"pcm_decoder_implemented\":false}\n",(unsigned long long)checks,(unsigned long long)bit_checks,(unsigned long long)header_checks,(unsigned long long)packets,(unsigned long long)prefixes,(unsigned long long)mutations,(unsigned long long)accepted_mutations,(unsigned long long)controls,nb_mask,wb_mask,uwb_mask,(unsigned long long)lsp_cases,(unsigned long long)lsp_words,(unsigned long long)lsp_truncated);return 0;
}
