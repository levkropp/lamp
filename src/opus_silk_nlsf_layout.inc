; NLSF reconstruction request,40 bytes. All buffers separate, caller-owned.
SN_IND EQU 0                   ; first-stage and10/16 residual signed bytes
SN_OUT EQU 8                   ; 10/16 int16 Q15 NLSF output
SN_WORK EQU 16                 ;112-byte workspace below
SN_FS EQU 24                   ;8/12/16 kHz
SN_IND_CAP EQU 28              ;byte count >=order+1
SN_OUT_CAP EQU 32              ;int16 count >=order
SN_WORK_CAP EQU 36             ;byte count >=112
NW_IX EQU 0                    ;16 int16 entropy-selector offsets
NW_PRED EQU 32                 ;16 predictor bytes
NW_RES EQU 48                  ;16 int16 Q10 residuals
NW_WEIGHT EQU 80               ;16 int16 Q2 Laroia weights
NW_SIZE EQU 112
; In-place fixed-codebook stabilization request,16 bytes.
NS_OUT EQU 0
NS_FS EQU 8
NS_CAP EQU 12                  ;int16 count >=order
