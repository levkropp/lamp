; SILK packet VAD/LBRR header and redundant-data skip request,64 bytes.
PH_STATE EQU 0                 ;1/2 contiguous3908-byte channel states
PH_META EQU 8                  ;64-byte VAD/LBRR metadata below
PH_EC EQU 16                   ;64-byte primed range context
PH_WORK EQU 24                 ;1280-byte pulse scratch
PH_FRAMES EQU 32               ;1/2/3 frames
PH_CHANNELS EQU 36             ;1/2 channels
PH_MODE EQU 40                 ;0 normal (skip FEC)/2 FEC (preserve payload)
PH_STATE_CAP EQU 44            ;bytes
PH_META_CAP EQU 48             ;bytes>=64
PH_EC_CAP EQU 52               ;bytes>=64
PH_WORK_CAP EQU 56             ;bytes>=1280
PD_VAD EQU 0                   ;2x3 int32 flags,active frames replaced
PD_LBRR EQU 24                 ;2x3 int32 flags,active channels cleared/replaced
PD_FLAG EQU 48                 ;2 int32 per-channel LBRR flags
PD_FRAMES EQU 56               ;int32 current frame count
PD_CHANNELS EQU 60             ;int32 current channel count
PD_SIZE EQU 64
