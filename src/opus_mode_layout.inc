; Complete mono/stereo Opus mode-frame orchestration; fixed caller storage.
MO_TAG EQU 0
MO_CHANNELS EQU 4
MO_FS EQU 8
MO_STREAM EQU 12
MO_MODE EQU 16                 ;1 SILK,2 hybrid,3 CELT
MO_END EQU 20                  ;CELT bandwidth end13/17/19/21
MO_PREV EQU 24
MO_FRAME EQU 28                ;TOC frame samples at API rate
MO_RED EQU 32                  ;previous SILK-to-CELT redundancy
MO_RANGE EQU 36
MO_ERROR EQU 40
MO_CTRL EQU 48                 ;24-byte SILK API control
MO_SILK EQU 72                 ;8536-byte SILK decoder
MO_CELT EQU 8608               ;18272-byte CELT decoder
MO_SIZE EQU 26880
MO_MAGIC EQU 31444f4dh         ;MOD1
; Init request24 bytes.
MI_STATE EQU 0
MI_FS EQU 8
MI_CHANNELS EQU 12
MI_CAP EQU 16
; Frame request64 bytes. Payload excludes TOC; CONFIG is its five bits.
MF_STATE EQU 0
MF_DATA EQU 8
MF_PCM EQU 16                  ;interleaved float
MF_WORK EQU 24
MF_LEN EQU 32                  ;0..1275;<=1 invokes PLC
MF_CONFIG EQU 36               ;0..31
MF_STREAM EQU 40               ;1/2 encoded channels
MF_COUNT EQU 44                ;output limit;0 uses TOC/stored frame
MF_FEC EQU 48                  ;0/1
MF_STATE_CAP EQU 52
MF_WORK_CAP EQU 56
MF_PCM_CAP EQU 60              ;float elements
; Normal frames<=60ms; PLC<=120ms in safe whole20ms long blocks.
MW_EC EQU 0                    ;64-byte range decoder
MW_SILK EQU 64                 ;5760 int16 (60ms stereo48kHz)
MW_TRANS EQU 11584             ;480 float (5ms stereo48kHz)
MW_RED EQU 13504               ;480 float
MW_CODEC EQU 15424             ;44048-byte reused SILK/CELT workspace
MW_LOCAL EQU 59472
MW_CHILD EQU 59472             ;one nested PLC call,never further nested
MW_SIZE EQU 118944
