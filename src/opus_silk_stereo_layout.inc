; Stereo entropy request,32 bytes. Outputs/entropy separate.
ST_EC EQU 0                    ;64-byte primed range context
ST_OUT EQU 8                   ;int32 predictor pair or mid-only flag
ST_KIND EQU 16                 ;0 predictors/1 mid-only
ST_OUT_CAP EQU 20              ;int32 count>=2/1
ST_EC_CAP EQU 24               ;bytes>=64
; Stereo reconstruction request,56 bytes. Buffers separate.
SM_STATE EQU 0                 ;12-byte normative history
SM_MID EQU 8                   ;int16 length+2,output left at1..length
SM_SIDE EQU 16                 ;int16 length+2,output right at1..length
SM_PRED EQU 24                 ;2 immutable int32 Q13 predictors
SM_FS EQU 32                   ;8/12/16 kHz
SM_N EQU 36                    ;fs*10 orfs*20 samples
SM_STATE_CAP EQU 40            ;bytes>=12
SM_MID_CAP EQU 44              ;int16 count>=N+2
SM_SIDE_CAP EQU 48             ;int16 count>=N+2
SM_PRED_CAP EQU 52             ;int32 count>=2
SN_PRED EQU 0                  ;2 int16 prior Q13 predictors
SN_MID EQU 4                   ;2 int16 mid history
SN_SIDE EQU 8                  ;2 int16 side history
