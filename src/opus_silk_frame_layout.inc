# One SILK channel's frame history. All fields caller-owned.
.equ FN_CORE, 0                  #2320-byte core state
.equ FN_PARAM, 2320              #48-byte parameter history
.equ FN_PREVIOUS, 2368           #8-byte entropy index history
.equ FN_IND, 2376                #36-byte side information
.equ FN_PLC, 2412                #92-byte concealment history
.equ FN_CNG, 2504                #1388-byte comfort-noise history
.equ FN_FS, 3892                 #8/12/16 kHz
.equ FN_SUBFR, 3896              #2/4 five-ms subframes
.equ FN_ERROR, 3900              #sticky0/1 failure
.equ FN_TAG, 3904                #initialization signature
.equ FN_TAG_VALUE, 0x464b4c53
.equ FN_SIZE, 3908
# Init/config request,24 bytes. Config preserves decoding history except
# normative rate-change reset; init clears all history and sticky failure.
.equ FI_STATE, 0
.equ FI_FS, 8
.equ FI_SUBFR, 12
.equ FI_STATE_CAP, 16            #bytes>=3908
# Decode request,64 bytes. Buffers must be separate.
.equ FF_STATE, 0                 #3908-byte history
.equ FF_EC, 8                    #primed64-byte range context,nullable for loss
.equ FF_PCM, 16                  #int16 mono source-rate output
.equ FF_WORK, 24                 #5360-byte scratch
.equ FF_MODE, 32                 #0 normal/1 lost/2 redundant (FEC)
.equ FF_VAD, 36                  #0/1 current frame VAD
.equ FF_LBRR, 40                 #0/1 redundant frame available
.equ FF_COND, 44                 #0 independent/1 noLTPscale/2 conditional
.equ FF_STATE_CAP, 48            #bytes
.equ FF_EC_CAP, 52               #bytes,required only when decoding
.equ FF_PCM_CAP, 56              #int16 elements>=full frame
.equ FF_WORK_CAP, 60             #bytes
.equ FW_CTRL, 0                  #140-byte controls,4 bytes padding
.equ FW_PULSES, 144              #320 int32 excitation pulses
.equ FW_TEMP, 1424               #3936-byte reused core/PLC/CNG scratch
.equ FW_SIZE, 5360
