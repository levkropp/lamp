; SILK packet-loss update/concealment request,96 bytes. Buffers separate.
PL_STATE EQU 0                 ;92-byte normative PLC state below
PL_CORE EQU 8                  ;mutable2320-byte core history
PL_PARAM EQU 16                ;read-only48-byte parameter history
PL_CTRL EQU 24                 ;mutable140-byte controls
PL_IND EQU 32                  ;read-only36-byte indices
PL_PCM EQU 40                  ;int16 source-rate output
PL_WORK EQU 48                 ;3552-byte workspace
PL_FS EQU 56                   ;8/12/16 kHz
PL_SUBFR EQU 60                ;2/4 five-ms subframes
PL_LOST EQU 64                 ;0 update/1 conceal
PL_STATE_CAP EQU 68            ;bytes
PL_CORE_CAP EQU 72             ;bytes
PL_PARAM_CAP EQU 76            ;bytes
PL_CTRL_CAP EQU 80             ;bytes
PL_IND_CAP EQU 84              ;bytes
PL_PCM_CAP EQU 88              ;int16 count>=full frame
PL_WORK_CAP EQU 92             ;bytes
PN_PITCH EQU 0                 ;int32 Q8 lag
PN_LTP EQU 4                   ;5 int16 Q14 taps
PN_LPC EQU 14                  ;16 int16 Q12 taps
PN_LAST EQU 48                 ;int32 last-frame-lost
PN_RNG EQU 52                  ;int32 seed
PN_SCALE EQU 56                ;int16 Q14 random gain
PN_ENERGY EQU 60               ;nonnegative int32 concealment energy
PN_SHIFT EQU 64                ;int32 energy shift
PN_LTP_SCALE EQU 68            ;int16 Q14 prior LTP scale
PN_GAINS EQU 72                ;2 positive int32 Q16 gains
PN_FS EQU 80                   ;prior internal kHz
PN_SUBFR EQU 84                ;prior subframe count
PN_SUBLEN EQU 88               ;prior subframe length
PN_SIZE EQU 92
PW_EXC EQU 0                   ;160 int16 scaled excitation samples
PW_COEF EQU 320                ;16 int16 Q12 coefficients
PW_LTP EQU 352                 ;320 int16 rewhitened history samples
PW_Q14 EQU 992                 ;640 int32 LTP/LPC samples
PW_SIZE EQU 3552
; Concealment/recovery glue request,32 bytes.
PG_STATE EQU 0                 ;92-byte mutable PLC state
PG_PCM EQU 8                   ;in-place int16 PCM
PG_N EQU 16                    ;1..320 samples
PG_LOSS EQU 20                 ;current nonnegative loss count
PG_STATE_CAP EQU 24            ;bytes
PG_PCM_CAP EQU 28              ;int16 count
; Energy request,32 bytes. Separate outputs/input.
PE_ENERGY EQU 0                ;int32 output
PE_SHIFT EQU 8                 ;int32 output
PE_IN EQU 16                   ;immutable int16 samples
PE_N EQU 24                    ;0..480 samples
PE_IN_CAP EQU 28               ;int16 count
