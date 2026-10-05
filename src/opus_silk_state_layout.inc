# Stateful SILK parameter request,48 bytes. Writable buffers separate.
.equ SD_IND, 0                   # mutable normative SideInfoIndices,36 bytes
.equ SD_STATE, 8                 # parameter history below,48 bytes
.equ SD_OUT, 16                  # normative decoder control,140 bytes
.equ SD_FS, 24                   # internal8/12/16 kHz
.equ SD_SUBFR, 28                #2/4
.equ SD_COND, 32                 #0/1/2 coding mode
.equ SD_IND_CAP, 36              #bytes>=36
.equ SD_STATE_CAP, 40            #bytes>=48
.equ SD_OUT_CAP, 44              #bytes>=140
.equ DS_GAIN, 0                  #last gain index byte0..63
.equ DS_PREV, 4                  #16 int16 previous NLSFs,active0..32767
.equ DS_FIRST, 36                #first frame after reset,0/1
.equ DS_LOSS, 40                 #nonnegative loss counter
.equ DS_SIZE, 48                 #padding retained
.equ DC_PITCH, 0                 #4 int32
.equ DC_GAINS, 16                #4 int32 Q16
.equ DC_PRED, 32                 #two16-int16 Q12 filters
.equ DC_LTP, 96                  #20 int16 Q14
.equ DC_SCALE, 136               #int32 Q14
.equ DC_SIZE, 140
