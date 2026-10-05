# SILK packet VAD/LBRR header and redundant-data skip request,64 bytes.
.equ PH_STATE, 0                 #1/2 contiguous3908-byte channel states
.equ PH_META, 8                  #64-byte VAD/LBRR metadata below
.equ PH_EC, 16                   #64-byte primed range context
.equ PH_WORK, 24                 #1280-byte pulse scratch
.equ PH_FRAMES, 32               #1/2/3 frames
.equ PH_CHANNELS, 36             #1/2 channels
.equ PH_MODE, 40                 #0 normal (skip FEC)/2 FEC (preserve payload)
.equ PH_STATE_CAP, 44            #bytes
.equ PH_META_CAP, 48             #bytes>=64
.equ PH_EC_CAP, 52               #bytes>=64
.equ PH_WORK_CAP, 56             #bytes>=1280
.equ PD_VAD, 0                   #2x3 int32 flags,active frames replaced
.equ PD_LBRR, 24                 #2x3 int32 flags,active channels cleared/replaced
.equ PD_FLAG, 48                 #2 int32 per-channel LBRR flags
.equ PD_FRAMES, 56               #int32 current frame count
.equ PD_CHANNELS, 60             #int32 current channel count
.equ PD_SIZE, 64
