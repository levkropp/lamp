# Raw allpass up2 request,40 bytes. Buffers separate.
.equ RU_STATE, 0                 #six int32 Q10 history entries
.equ RU_OUT, 8                   #int16,2*N elements
.equ RU_IN, 16                   #int16,N elements
.equ RU_N, 24                    #0..960
.equ RU_STATE_CAP, 28            #int32 count>=6
.equ RU_OUT_CAP, 32              #int16 count
.equ RU_IN_CAP, 36               #int16 count
# Raw AR2 request,56 bytes. Buffers separate.
.equ RA_STATE, 0                 #two int32 history entries
.equ RA_OUT, 8                   #int32 Q8 output
.equ RA_IN, 16                   #int16 input
.equ RA_COEF, 24                 #two int16 Q14 coefficients
.equ RA_N, 32                    #0..480
.equ RA_STATE_CAP, 36            #int32 count
.equ RA_OUT_CAP, 40              #int32 count
.equ RA_IN_CAP, 44               #int16 count
.equ RA_COEF_CAP, 48             #int16 count
# Decoder resampler init request,24 bytes.
.equ RI_STATE, 0
.equ RI_IN, 8                    #8000/12000/16000 Hz
.equ RI_OUT, 12                  #8000/12000/16000/24000/48000 Hz
.equ RI_CAP, 16                  #bytes>=304
# Decoder resampling request,56 bytes. All buffers separate.
.equ RR_STATE, 0
.equ RR_OUT, 8                   #int16 output
.equ RR_IN, 16                   #int16 input
.equ RR_WORK, 24                 #736-byte workspace
.equ RR_N, 32                    #1..60 ms,whole milliseconds at input rate
.equ RR_IN_CAP, 36               #int16 count
.equ RR_OUT_CAP, 40              #int16 count
.equ RR_STATE_CAP, 44            #bytes
.equ RR_WORK_CAP, 48             #bytes
# Normative x64 decoder resampler state,304 bytes.
.equ RS_IIR, 0                   #six int32
.equ RS_FIR, 24                  #36 int32 (up-FIR uses first8 int16 only)
.equ RS_DELAY, 168               #48 int16
.equ RS_FUNC, 264                #0 copy,1 up2,2 up-FIR,3 down-FIR
.equ RS_BATCH, 268
.equ RS_RATIO, 272               #input index increment,Q16
.equ RS_ORDER, 276
.equ RS_FRACS, 280
.equ RS_IN, 284                  #kHz
.equ RS_OUT, 288                 #kHz
.equ RS_INPUT_DELAY, 292
.equ RS_COEF, 296                #validated internal table pointer
.equ RS_SIZE, 304
.equ RR_WORK_SIZE, 736
