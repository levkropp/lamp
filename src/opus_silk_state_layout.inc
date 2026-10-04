; Stateful SILK parameter request,48 bytes. Writable buffers separate.
SD_IND EQU 0                   ; mutable normative SideInfoIndices,36 bytes
SD_STATE EQU 8                 ; parameter history below,48 bytes
SD_OUT EQU 16                  ; normative decoder control,140 bytes
SD_FS EQU 24                   ; internal8/12/16 kHz
SD_SUBFR EQU 28                ;2/4
SD_COND EQU 32                 ;0/1/2 coding mode
SD_IND_CAP EQU 36              ;bytes>=36
SD_STATE_CAP EQU 40            ;bytes>=48
SD_OUT_CAP EQU 44              ;bytes>=140
DS_GAIN EQU 0                  ;last gain index byte0..63
DS_PREV EQU 4                  ;16 int16 previous NLSFs,active0..32767
DS_FIRST EQU 36                ;first frame after reset,0/1
DS_LOSS EQU 40                 ;nonnegative loss counter
DS_SIZE EQU 48                 ;padding retained
DC_PITCH EQU 0                 ;4 int32
DC_GAINS EQU 16                ;4 int32 Q16
DC_PRED EQU 32                 ;two16-int16 Q12 filters
DC_LTP EQU 96                  ;20 int16 Q14
DC_SCALE EQU 136               ;int32 Q14
DC_SIZE EQU 140
