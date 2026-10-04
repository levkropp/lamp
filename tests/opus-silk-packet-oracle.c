/* Test-only packet flags/LBRR skipping against the unchanged dec_API block. */
#define SILK_FRAME_ORACLE_EMBEDDED
#include "opus-silk-frame-oracle.c"
typedef struct {int vad[2][3],lbrr[2][3],flag[2],frames,channels;} PacketMeta;
typedef struct {FrameState *state;PacketMeta *meta;ec_dec *ec;void *work;unsigned frames,channels,mode,state_cap,meta_cap,ec_cap,work_cap;} Header;
int op_silk_packet_header(Header *);
void lamp_silk_packet_reference(silk_decoder_state *,int,int,ec_dec *);
typedef char header_sizes[(sizeof(PacketMeta)==64&&sizeof(Header)==64)?1:-1];
typedef struct {uint64_t before;FrameState states[2];uint64_t after;} PairGuard;
typedef struct {uint64_t before;PacketMeta meta;uint64_t after;} MetaGuard;
typedef struct {uint64_t before;unsigned char value[1280];uint64_t after;} HeaderWork;
static unsigned sh_headers,sh_skip,sh_stereo,sh_midonly,sh_conditional,sh_late,sh_guards;
static unsigned long long sh_state_bytes;
static void sh_metadata(PacketMeta *meta,const silk_decoder_state *ref,int frames,int channels){
 for(int n=0;n<2;n++){memcpy(meta->vad[n],ref[n].VAD_flags,12);memcpy(meta->lbrr[n],ref[n].LBRR_flags,12);meta->flag[n]=ref[n].LBRR_flag;}meta->frames=frames;meta->channels=channels;
}
static int sh_header(FrameState *states,PacketMeta *meta,silk_decoder_state *ref,ec_dec *ec,int frames,int channels,int mode){
 PairGuard guard;memset(&guard,0xa5,sizeof(guard));guard.before=0x13579bdf98765432ULL;guard.after=0x2468ace012345678ULL;memcpy(guard.states,states,sizeof(guard.states));PairGuard expected=guard;
 MetaGuard mg;memset(&mg,0xa5,sizeof(mg));mg.before=guard.before;mg.after=guard.after;mg.meta=*meta;MetaGuard em=mg;HeaderWork work;memset(&work,0xa5,sizeof(work));work.before=guard.before;work.after=guard.after;ec_dec a=*ec,b=*ec;
 for(int i=0;i<channels;i++){ref[i].nFramesPerPacket=frames;ref[i].nFramesDecoded=0;}
 lamp_silk_packet_reference(ref,channels,mode,&a);for(int i=0;i<2;i++)sf_map(&expected.states[i],&ref[i]);sh_metadata(&em.meta,ref,frames,channels);
 Header r={guard.states,&mg.meta,&b,work.value,frames,channels,mode,channels*3908,64,64,1280},saved=r;
 if(!op_silk_packet_header(&r)||memcmp(&a,&b,sizeof(a))||memcmp(&guard,&expected,sizeof(guard))||memcmp(&mg,&em,sizeof(mg))||memcmp(&r,&saved,sizeof(r))||work.before!=guard.before||work.after!=guard.after){
  printf("Header%u fs%d subfr%d frames%d channels%d mode%d\n",sh_headers,states[0].fs,states[0].subfr,frames,channels,mode);
  if(memcmp(&a,&b,sizeof(a)))printf("Entropy tell%d/%d\n",ec_tell(&a),ec_tell(&b));const unsigned char *x=(const unsigned char *)expected.states,*y=(const unsigned char *)guard.states;for(unsigned i=0;i<sizeof(guard.states);i++)if(x[i]!=y[i]){printf("State byte%u %u/%u\n",i,x[i],y[i]);break;}return 0;
 }
 if(!mode)for(int f=0;f<frames;f++)for(int n=0;n<channels;n++)if(mg.meta.lbrr[n][f]){sh_skip++;if(f&&mg.meta.lbrr[n][f-1])sh_conditional++;if(channels==2&&n==0){sh_stereo++;if(!mg.meta.lbrr[1][f])sh_midonly++;}}
 memcpy(states,guard.states,sizeof(guard.states));*meta=mg.meta;*ec=b;sh_headers++;sh_state_bytes+=channels*3908;return 1;
}
static int sh_sequences(void){
 const int rates[]={8,12,16};unsigned char payload[1275];
 for(int rate=0;rate<3;rate++)for(int layout=0;layout<4;layout++)for(int channels=1;channels<=2;channels++)for(int mode=0;mode<=2;mode+=2)for(unsigned trial=0;trial<128;trial++){
  int subfr=layout?4:2,frames=layout?layout:1,fs=rates[rate];FrameState states[2];silk_decoder_state ref[2];for(int n=0;n<2;n++){if(!sf_init(&states[n],&ref[n],fs,subfr))return 0;for(int f=0;f<3;f++){ref[n].VAD_flags[f]=next()%2;ref[n].LBRR_flags[f]=next()%2;}ref[n].LBRR_flag=next()%2;}
  PacketMeta meta;sh_metadata(&meta,ref,frames,channels);
  for(unsigned packet=0;packet<4;packet++){
   unsigned len=trial%6==0?0:trial%6==1?1:trial%6==2?1275:next()%1276;for(unsigned i=0;i<len;i++)payload[i]=(unsigned char)(trial%8==0?0:trial%8==1?255:next());ec_dec ec;memset(&ec,0,sizeof(ec));ec_dec_init(&ec,payload,len);if(trial%3==0)ec_dec_bit_logp(&ec,3);
   if(!sh_header(states,&meta,ref,&ec,frames,channels,mode))return 0;
   if(channels==1)for(int f=0;f<frames;f++)if(!sf_frame(&states[0],&ref[0],&ec,mode,meta.vad[0][f],meta.lbrr[0][f],f?2:0))return 0;
  }
 }return 1;
}
static int sh_invalid(void){
 FrameState states[2];silk_decoder_state ref[2];for(int n=0;n<2;n++)if(!sf_init(&states[n],&ref[n],16,4))return 0;PacketMeta meta;memset(&meta,0xa5,sizeof(meta));unsigned char payload[1275]={0};ec_dec ec;memset(&ec,0,sizeof(ec));ec_dec_init(&ec,payload,sizeof(payload));unsigned char work[1280];memset(work,0xa5,sizeof(work));Header base={states,&meta,&ec,work,3,2,0,7816,64,64,1280};
 for(unsigned k=0;k<37;k++){
  Header r=base;FrameState original[2];memcpy(original,states,sizeof(states));ec_dec original_ec=ec;
  switch(k){case 0:r.state=NULL;break;case 1:r.meta=NULL;break;case 2:r.ec=NULL;break;case 3:r.work=NULL;break;case 4:r.frames=0;break;case 5:r.frames=4;break;case 6:r.channels=0;break;case 7:r.channels=3;break;case 8:r.mode=1;break;case 9:r.state_cap=7815;break;case 10:r.meta_cap=63;break;case 11:r.ec_cap=63;break;case 12:r.work_cap=1279;break;case 13:states[1].tag=0;break;case 14:states[1].error=1;break;case 15:states[1].fs=0;break;case 16:states[1].fs=12;break;case 17:states[1].subfr=3;break;case 18:states[1].subfr=2;break;case 19:states[0].subfr=states[1].subfr=2;break;case 20:states[1].previous.signal=3;break;case 21:states[1].previous.lag=32768;break;case 22:states[0].previous.lag=-32769;break;case 23:ec.buf=NULL;break;case 24:ec.storage=1276;break;case 25:ec.offs=1276;break;case 26:ec.end_offs=1276;break;case 27:ec.rng=0x800000;break;case 28:ec.rng=0x80000001;break;case 29:ec.val=ec.rng;break;case 30:ec.nend_bits=33;break;case 31:ec.nbits_total=32769;break;case 32:r.frames=UINT32_MAX;break;case 33:r.channels=UINT32_MAX;break;case 34:r.mode=UINT32_MAX;break;case 35:states[0].tag=0;break;case 36:states[0].error=1;break;}
  Header saved=r;FrameState prior[2];memcpy(prior,states,sizeof(states));ec_dec prior_ec=ec;PacketMeta prior_meta=meta;unsigned char prior_work[1280];memcpy(prior_work,work,sizeof(work));
  if(op_silk_packet_header(&r)||memcmp(&r,&saved,sizeof(r))||memcmp(states,prior,sizeof(states))||memcmp(&ec,&prior_ec,sizeof(ec))||memcmp(&meta,&prior_meta,sizeof(meta))||memcmp(work,prior_work,sizeof(work))){printf("Header guard%u\n",k);return 0;}memcpy(states,original,sizeof(states));ec=original_ec;sh_guards++;
 }
 if(op_silk_packet_header(NULL))return 0;sh_guards++;return 1;
}
static int sh_sticky(void){
 FrameState states[2];silk_decoder_state ref[2];for(int n=0;n<2;n++)if(!sf_init(&states[n],&ref[n],16,4))return 0;PacketMeta meta;sh_metadata(&meta,ref,3,2);unsigned char payload[1275];memset(payload,255,sizeof(payload));ec_dec ec;memset(&ec,0,sizeof(ec));ec_dec_init(&ec,payload,sizeof(payload));ec.nbits_total=32768;unsigned char work[1280];memset(work,0xa5,sizeof(work));Header r={states,&meta,&ec,work,3,2,0,7816,64,64,1280};
 if(op_silk_packet_header(&r)||states[0].error!=1||states[1].error!=1){puts("Header late failure not marked");return 0;}FrameState failed[2];memcpy(failed,states,sizeof(states));PacketMeta prior_meta=meta;ec_dec prior_ec=ec;unsigned char prior_work[1280];memcpy(prior_work,work,sizeof(work));
 if(op_silk_packet_header(&r)||memcmp(states,failed,sizeof(states))||memcmp(&meta,&prior_meta,sizeof(meta))||memcmp(&ec,&prior_ec,sizeof(ec))||memcmp(work,prior_work,sizeof(work))){puts("Header failure not sticky");return 0;}
 for(int n=0;n<2;n++)if(!sf_init(&states[n],&ref[n],16,4))return 0;sh_metadata(&meta,ref,3,2);memset(&ec,0,sizeof(ec));ec_dec_init(&ec,payload,sizeof(payload));if(!sh_header(states,&meta,ref,&ec,3,2,0))return 0;sh_late++;return 1;
}
int main(void){if(!sh_sequences()||!sh_invalid()||!sh_sticky())return 1;printf("SILK packet header: %u exact entropy/metadata/history headers, %u skipped FEC frames (%u conditional, %u stereo predictors, %u mid-only flags), %u connected mono header/frame PCM checks, %llu channel-history bytes, %u late/sticky/reset checks, %u guards\n",sh_headers,sh_skip,sh_conditional,sh_stereo,sh_midonly,sf_frames,sh_state_bytes,sh_late,sh_guards);return 0;}
