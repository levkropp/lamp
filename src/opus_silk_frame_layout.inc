; One SILK channel's frame history. All fields caller-owned.
FN_CORE EQU 0                  ;2320-byte core state
FN_PARAM EQU 2320              ;48-byte parameter history
FN_PREVIOUS EQU 2368           ;8-byte entropy index history
FN_IND EQU 2376                ;36-byte side information
FN_PLC EQU 2412                ;92-byte concealment history
FN_CNG EQU 2504                ;1388-byte comfort-noise history
FN_FS EQU 3892                 ;8/12/16 kHz
FN_SUBFR EQU 3896              ;2/4 five-ms subframes
FN_ERROR EQU 3900              ;sticky0/1 failure
FN_TAG EQU 3904                ;initialization signature
FN_TAG_VALUE EQU 464b4c53h
FN_SIZE EQU 3908
; Init/config request,24 bytes. Config preserves decoding history except
; normative rate-change reset; init clears all history and sticky failure.
FI_STATE EQU 0
FI_FS EQU 8
FI_SUBFR EQU 12
FI_STATE_CAP EQU 16            ;bytes>=3908
; Decode request,64 bytes. Buffers must be separate.
FF_STATE EQU 0                 ;3908-byte history
FF_EC EQU 8                    ;primed64-byte range context,nullable for loss
FF_PCM EQU 16                  ;int16 mono source-rate output
FF_WORK EQU 24                 ;5360-byte scratch
FF_MODE EQU 32                 ;0 normal/1 lost/2 redundant (FEC)
FF_VAD EQU 36                  ;0/1 current frame VAD
FF_LBRR EQU 40                 ;0/1 redundant frame available
FF_COND EQU 44                 ;0 independent/1 noLTPscale/2 conditional
FF_STATE_CAP EQU 48            ;bytes
FF_EC_CAP EQU 52               ;bytes,required only when decoding
FF_PCM_CAP EQU 56              ;int16 elements>=full frame
FF_WORK_CAP EQU 60             ;bytes
FW_CTRL EQU 0                  ;140-byte controls,4 bytes padding
FW_PULSES EQU 144              ;320 int32 excitation pulses
FW_TEMP EQU 1424               ;3936-byte reused core/PLC/CNG scratch
FW_SIZE EQU 5360
