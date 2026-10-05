# Complete mono/stereo Opus mode-frame orchestration; fixed caller storage.
.equ MO_TAG, 0
.equ MO_CHANNELS, 4
.equ MO_FS, 8
.equ MO_STREAM, 12
.equ MO_MODE, 16                 #1 SILK,2 hybrid,3 CELT
.equ MO_END, 20                  #CELT bandwidth end13/17/19/21
.equ MO_PREV, 24
.equ MO_FRAME, 28                #TOC frame samples at API rate
.equ MO_RED, 32                  #previous SILK-to-CELT redundancy
.equ MO_RANGE, 36
.equ MO_ERROR, 40
.equ MO_CTRL, 48                 #24-byte SILK API control
.equ MO_SILK, 72                 #8536-byte SILK decoder
.equ MO_CELT, 8608               #18272-byte CELT decoder
.equ MO_SIZE, 26880
.equ MO_MAGIC, 0x31444f4d         #MOD1
# Init request24 bytes.
.equ MI_STATE, 0
.equ MI_FS, 8
.equ MI_CHANNELS, 12
.equ MI_CAP, 16
# Frame request64 bytes. Payload excludes TOC; CONFIG is its five bits.
.equ MF_STATE, 0
.equ MF_DATA, 8
.equ MF_PCM, 16                  #interleaved float
.equ MF_WORK, 24
.equ MF_LEN, 32                  #0..1275;<=1 invokes PLC
.equ MF_CONFIG, 36               #0..31
.equ MF_STREAM, 40               #1/2 encoded channels
.equ MF_COUNT, 44                #output limit;0 uses TOC/stored frame
.equ MF_FEC, 48                  #0/1
.equ MF_STATE_CAP, 52
.equ MF_WORK_CAP, 56
.equ MF_PCM_CAP, 60              #float elements
# Normal frames<=60ms; PLC<=120ms in safe whole20ms long blocks.
.equ MW_EC, 0                    #64-byte range decoder
.equ MW_SILK, 64                 #5760 int16 (60ms stereo48kHz)
.equ MW_TRANS, 11584             #480 float (5ms stereo48kHz)
.equ MW_RED, 13504               #480 float
.equ MW_CODEC, 15424             #44048-byte reused SILK/CELT workspace
.equ MW_LOCAL, 59472
.equ MW_CHILD, 59472             #one nested PLC call,never further nested
.equ MW_SIZE, 118944
