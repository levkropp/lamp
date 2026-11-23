/* Packet seeking must not relax a subsequently opened native MPEG stream. */
#include "lamp-test.h"
LAMP_ABI int decoder_open(const lamp_char*);
LAMP_ABI void decoder_close(void);
LAMP_ABI uint64_t decoder_seek(uint64_t);
extern unsigned decode_error,track_active;
extern uint64_t output_frames;
int lamp_main(int argc,lamp_char**argv){
 if(argc!=3)return 2;
 if(decoder_open(argv[2])||!decode_error){fprintf(stderr,"cold missing reservoir accepted\n");return 1;}decoder_close();
 if(!decoder_open(argv[1])||decode_error||!track_active||!output_frames)return 1;
 uint64_t target=output_frames/2,base=decoder_seek(target);if(base>target||decode_error)return 1;decoder_close();
 if(decoder_open(argv[2])||!decode_error){fprintf(stderr,"missing reservoir accepted after packet seek/close\n");return 1;}decoder_close();
 puts("{\"result\":\"passed\",\"cold_rejection\":true,\"reopened_rejection\":true}");return 0;
}
