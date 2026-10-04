; Raw allpass up2 request,40 bytes. Buffers separate.
RU_STATE EQU 0                 ;six int32 Q10 history entries
RU_OUT EQU 8                   ;int16,2*N elements
RU_IN EQU 16                   ;int16,N elements
RU_N EQU 24                    ;0..960
RU_STATE_CAP EQU 28            ;int32 count>=6
RU_OUT_CAP EQU 32              ;int16 count
RU_IN_CAP EQU 36               ;int16 count
; Raw AR2 request,56 bytes. Buffers separate.
RA_STATE EQU 0                 ;two int32 history entries
RA_OUT EQU 8                   ;int32 Q8 output
RA_IN EQU 16                   ;int16 input
RA_COEF EQU 24                 ;two int16 Q14 coefficients
RA_N EQU 32                    ;0..480
RA_STATE_CAP EQU 36            ;int32 count
RA_OUT_CAP EQU 40              ;int32 count
RA_IN_CAP EQU 44               ;int16 count
RA_COEF_CAP EQU 48             ;int16 count
; Decoder resampler init request,24 bytes.
RI_STATE EQU 0
RI_IN EQU 8                    ;8000/12000/16000 Hz
RI_OUT EQU 12                  ;8000/12000/16000/24000/48000 Hz
RI_CAP EQU 16                  ;bytes>=304
; Decoder resampling request,56 bytes. All buffers separate.
RR_STATE EQU 0
RR_OUT EQU 8                   ;int16 output
RR_IN EQU 16                   ;int16 input
RR_WORK EQU 24                 ;736-byte workspace
RR_N EQU 32                    ;1..60 ms,whole milliseconds at input rate
RR_IN_CAP EQU 36               ;int16 count
RR_OUT_CAP EQU 40              ;int16 count
RR_STATE_CAP EQU 44            ;bytes
RR_WORK_CAP EQU 48             ;bytes
; Normative x64 decoder resampler state,304 bytes.
RS_IIR EQU 0                   ;six int32
RS_FIR EQU 24                  ;36 int32 (up-FIR uses first8 int16 only)
RS_DELAY EQU 168               ;48 int16
RS_FUNC EQU 264                ;0 copy,1 up2,2 up-FIR,3 down-FIR
RS_BATCH EQU 268
RS_RATIO EQU 272               ;input index increment,Q16
RS_ORDER EQU 276
RS_FRACS EQU 280
RS_IN EQU 284                  ;kHz
RS_OUT EQU 288                 ;kHz
RS_INPUT_DELAY EQU 292
RS_COEF EQU 296                ;validated internal table pointer
RS_SIZE EQU 304
RR_WORK_SIZE EQU 736
