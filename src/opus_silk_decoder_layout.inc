# Stateful SILK mono/stereo packet decoder. One call emits one 10/20 ms
# frame; continue up to the packet's 1/2/3 frames using the same range.
.equ KD_CHANNEL0, 0
.equ KD_CHANNEL1, 3908
.equ KD_STEREO, 7816             #12-byte adaptive mid/side history
.equ KD_RS0, 7832                #304-byte decoder resampler
.equ KD_RS1, 8136
.equ KD_API_FS, 8440             #previous API Hz (0 until first frame)
.equ KD_API_CH, 8444             #previous API channels
.equ KD_INT_CH, 8448             #previous internal channels
.equ KD_PREV_MID, 8452           #previous mid-only flag
.equ KD_META, 8456               #64-byte packet VAD/LBRR metadata
.equ KD_DECODED, 8520            #two int32 per-channel frame counters
.equ KD_ERROR, 8528              #sticky0/1 failure
.equ KD_TAG, 8532
.equ KD_TAG_VALUE, 0x444b4c53
.equ KD_SIZE, 8536
# Init request,16 bytes. Clears all history/configuration/failure.
.equ KI_STATE, 0
.equ KI_CAP, 8                   #bytes>=8536
# Decode request,72 bytes. Buffers separate,caller-owned.
.equ KK_STATE, 0
.equ KK_EC, 8                    #primed64-byte range,nullable for loss
.equ KK_PCM, 16                  #int16 interleaved output
.equ KK_WORK, 24                 #8568-byte scratch below
.equ KK_CTRL, 32                 #24-byte control below,pitch updated
.equ KK_MODE, 40                 #0 normal/1 lost/2 FEC
.equ KK_NEW, 44                  #0 continue packet/1 new packet
.equ KK_STATE_CAP, 48            #bytes
.equ KK_EC_CAP, 52               #bytes>=64 unless loss
.equ KK_PCM_CAP, 56              #int16 elements>=samples*APIchannels
.equ KK_WORK_CAP, 60             #bytes>=8568
.equ KK_CTRL_CAP, 64             #bytes>=24
.equ KC_API_CH, 0                #1/2
.equ KC_INT_CH, 4                #1/2
.equ KC_API_FS, 8                #8000/12000/16000/24000/48000 Hz
.equ KC_INT_FS, 12               #8000/12000/16000 Hz
.equ KC_MS, 16                   #0/10/20/40/60 packet ms(0 assumes10ms)
.equ KC_PITCH, 20                #output previous pitch at48kHz
.equ KW_MID, 0                   #322 int16 samples incl2history
.equ KW_SIDE, 644                #322 int16 samples incl2history
.equ KW_RES, 1288                #960 int16 resampled samples
.equ KW_TEMP, 3208               #5360-byte reused frame/header/filter work
.equ KW_SIZE, 8568
