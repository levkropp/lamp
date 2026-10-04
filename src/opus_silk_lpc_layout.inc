; Bandwidth expansion request,24 bytes. In-place caller-owned filter.
SB_AR EQU 0                    ; int16/int32 coefficient pointer
SB_ORDER EQU 8                 ; 1..16
SB_CHIRP EQU 12                ; Q16,0..65536
SB_CAP EQU 16                  ; coefficient count
SB_WIDTH EQU 20                ; 16 or32 bits
; LPC inverse prediction gain request,16 bytes. Input unchanged.
SL_AR EQU 0                    ; int16 Q12 coefficients
SL_ORDER EQU 8                 ; 10/16
SL_CAP EQU 12                  ; int16 count
; NLSF-to-LPC request,32 bytes. Separate buffers, input unchanged.
SA_NLSF EQU 0                  ; int16 Q15,0..32767
SA_OUT EQU 8                   ; int16 Q12 prediction coefficients
SA_ORDER EQU 16                ; 10/16
SA_IN_CAP EQU 20               ; int16 count
SA_OUT_CAP EQU 24              ; int16 count
