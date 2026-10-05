# SILK core synthesis request,80 bytes. All writable buffers separate.
.equ SC_STATE, 0                 #2320-byte core history below
.equ SC_CTRL, 8                  #140-byte mutable normative control
.equ SC_IND, 16                  #36-byte read-only SideInfoIndices
.equ SC_PULSES, 24               #int32 excitation pulses
.equ SC_PCM, 32                  #int16 source-rate mono output
.equ SC_WORK, 40                 #3936-byte scratch below
.equ SC_FS, 48                   #8/12/16 kHz
.equ SC_SUBFR, 52                #2/4
.equ SC_STATE_CAP, 56            #bytes
.equ SC_CTRL_CAP, 60             #bytes
.equ SC_PULSE_CAP, 64            #int32 count
.equ SC_PCM_CAP, 68              #int16 count
.equ SC_WORK_CAP, 72             #bytes
.equ SC_IND_CAP, 76              #bytes
.equ CS_GAIN, 0                  #positive int32 previous Q16 gain
.equ CS_EXC, 4                   #320 int32 Q14 excitation samples
.equ CS_LPC, 1284                #16 int32 Q14 synthesis history
.equ CS_OUT, 1348                #480 int16 history samples
.equ CS_LAG, 2308                #previous pitch lag
.equ CS_SIGNAL, 2312             #previous signal type0..2
.equ CS_LOSS, 2316               #nonnegative loss count
.equ CS_SIZE, 2320
.equ SW_LTP, 0                   #320 int16 rewhitened samples
.equ SW_Q15, 640                 #640 int32 LTP history
.equ SW_RES, 3200                #80 int32 excitation+LTP samples
.equ SW_LPC, 3520                #96 int32 LPC samples
.equ SW_COEF, 3904               #16 int16 LPC coefficient copy
.equ SW_SIZE, 3936
