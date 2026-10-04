; Stateful SILK mono/stereo packet decoder. One call emits one 10/20 ms
; frame; continue up to the packet's 1/2/3 frames using the same range.
KD_CHANNEL0 EQU 0
KD_CHANNEL1 EQU 3908
KD_STEREO EQU 7816             ;12-byte adaptive mid/side history
KD_RS0 EQU 7832                ;304-byte decoder resampler
KD_RS1 EQU 8136
KD_API_FS EQU 8440             ;previous API Hz (0 until first frame)
KD_API_CH EQU 8444             ;previous API channels
KD_INT_CH EQU 8448             ;previous internal channels
KD_PREV_MID EQU 8452           ;previous mid-only flag
KD_META EQU 8456               ;64-byte packet VAD/LBRR metadata
KD_DECODED EQU 8520            ;two int32 per-channel frame counters
KD_ERROR EQU 8528              ;sticky0/1 failure
KD_TAG EQU 8532
KD_TAG_VALUE EQU 444b4c53h
KD_SIZE EQU 8536
; Init request,16 bytes. Clears all history/configuration/failure.
KI_STATE EQU 0
KI_CAP EQU 8                   ;bytes>=8536
; Decode request,72 bytes. Buffers separate,caller-owned.
KK_STATE EQU 0
KK_EC EQU 8                    ;primed64-byte range,nullable for loss
KK_PCM EQU 16                  ;int16 interleaved output
KK_WORK EQU 24                 ;8568-byte scratch below
KK_CTRL EQU 32                 ;24-byte control below,pitch updated
KK_MODE EQU 40                 ;0 normal/1 lost/2 FEC
KK_NEW EQU 44                  ;0 continue packet/1 new packet
KK_STATE_CAP EQU 48            ;bytes
KK_EC_CAP EQU 52               ;bytes>=64 unless loss
KK_PCM_CAP EQU 56              ;int16 elements>=samples*APIchannels
KK_WORK_CAP EQU 60             ;bytes>=8568
KK_CTRL_CAP EQU 64             ;bytes>=24
KC_API_CH EQU 0                ;1/2
KC_INT_CH EQU 4                ;1/2
KC_API_FS EQU 8                ;8000/12000/16000/24000/48000 Hz
KC_INT_FS EQU 12               ;8000/12000/16000 Hz
KC_MS EQU 16                   ;0/10/20/40/60 packet ms(0 assumes10ms)
KC_PITCH EQU 20                ;output previous pitch at48kHz
KW_MID EQU 0                   ;322 int16 samples incl2history
KW_SIDE EQU 644                ;322 int16 samples incl2history
KW_RES EQU 1288                ;960 int16 resampled samples
KW_TEMP EQU 3208               ;5360-byte reused frame/header/filter work
KW_SIZE EQU 8568
