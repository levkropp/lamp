; Gain reconstruction request, 48 bytes. All writable buffers separate.
SG_IND EQU 0                   ; signed-byte indices,2/4 entries
SG_OUT EQU 8                   ; positive int32 Q16 gains
SG_PREV EQU 16                 ; one signed-byte last gain index0..63
SG_SUBFR EQU 24                ; 2/4
SG_CONDITIONAL EQU 28          ; 0 independent,1 conditional
SG_IND_CAP EQU 32              ; bytes
SG_OUT_CAP EQU 36              ; int32 count
SG_PREV_CAP EQU 40             ; bytes
; Pitch/LTP reconstruction request,56 bytes. Input SideInfoIndices immutable.
SP_IND EQU 0                   ; 36-byte layout in opus_silk_indices_layout
SP_PITCH EQU 8                 ; 2/4 int32 lags
SP_LTP EQU 16                  ; 10/20 int16 Q14 taps
SP_SCALE EQU 24                ; one int32 Q14 scale
SP_FS EQU 32                   ; 8/12/16 kHz
SP_SUBFR EQU 36                ; 2/4
SP_PITCH_CAP EQU 40            ; int32 count
SP_LTP_CAP EQU 44              ; int16 count
SP_SCALE_CAP EQU 48            ; int32 count
