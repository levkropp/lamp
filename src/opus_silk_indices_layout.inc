; SILK side-information request, 56 bytes. Buffers separate, caller-owned.
SI_EC EQU 0                    ; 64-byte primed range context
SI_STATE EQU 8                 ; 8-byte prior-index state
SI_OUT EQU 16                  ; 36-byte normative SideInfoIndices layout
SI_FS EQU 24                   ; internal rate8/12/16 kHz
SI_SUBFR EQU 28                ; 2/4 five-millisecond subframes
SI_VAD EQU 32                  ; current frame VAD0/1
SI_LBRR EQU 36                 ; redundant-frame flag0/1
SI_COND EQU 40                 ; 0 independent,1 noLTPscale,2 conditional
SI_OUT_CAP EQU 44              ; bytes, >=36
SI_STATE_CAP EQU 48            ; bytes, >=8
SS_LAG EQU 0                   ; signed previous lag index, -32768..32767
SS_SIGNAL EQU 4                ; previous entropy signal type0..2
SX_GAINS EQU 0                 ; four signed bytes
SX_LTP EQU 4                   ; four signed bytes
SX_NLSF EQU 8                  ; seventeen signed bytes
SX_LAG EQU 26                  ; signed16, padding byte25 untouched
SX_CONTOUR EQU 28
SX_SIGNAL EQU 29
SX_OFFSET EQU 30
SX_INTERP EQU 31
SX_PER EQU 32
SX_SCALE EQU 33
SX_SEED EQU 34                 ; trailing padding byte35 untouched
; NLSF entropy-selector/predictor unpack request, 32 bytes.
SU_EC_IX EQU 0                 ; int16 array,10/16 elements
SU_PRED EQU 8                  ; uint8 array,10/16 elements
SU_FS EQU 16
SU_INDEX EQU 20                ; first-stage vector0..31
SU_EC_CAP EQU 24               ; int16 count
SU_PRED_CAP EQU 28             ; uint8 count
