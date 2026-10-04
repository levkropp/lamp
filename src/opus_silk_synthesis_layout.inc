; SILK core synthesis request,80 bytes. All writable buffers separate.
SC_STATE EQU 0                 ;2320-byte core history below
SC_CTRL EQU 8                  ;140-byte mutable normative control
SC_IND EQU 16                  ;36-byte read-only SideInfoIndices
SC_PULSES EQU 24               ;int32 excitation pulses
SC_PCM EQU 32                  ;int16 source-rate mono output
SC_WORK EQU 40                 ;3936-byte scratch below
SC_FS EQU 48                   ;8/12/16 kHz
SC_SUBFR EQU 52                ;2/4
SC_STATE_CAP EQU 56            ;bytes
SC_CTRL_CAP EQU 60             ;bytes
SC_PULSE_CAP EQU 64            ;int32 count
SC_PCM_CAP EQU 68              ;int16 count
SC_WORK_CAP EQU 72             ;bytes
SC_IND_CAP EQU 76              ;bytes
CS_GAIN EQU 0                  ;positive int32 previous Q16 gain
CS_EXC EQU 4                   ;320 int32 Q14 excitation samples
CS_LPC EQU 1284                ;16 int32 Q14 synthesis history
CS_OUT EQU 1348                ;480 int16 history samples
CS_LAG EQU 2308                ;previous pitch lag
CS_SIGNAL EQU 2312             ;previous signal type0..2
CS_LOSS EQU 2316               ;nonnegative loss count
CS_SIZE EQU 2320
SW_LTP EQU 0                   ;320 int16 rewhitened samples
SW_Q15 EQU 640                 ;640 int32 LTP history
SW_RES EQU 3200                ;80 int32 excitation+LTP samples
SW_LPC EQU 3520                ;96 int32 LPC samples
SW_COEF EQU 3904               ;16 int16 LPC coefficient copy
SW_SIZE EQU 3936
