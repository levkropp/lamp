; Fixed standard-mode CELT PLC pitch search request, 40 bytes.
PP_LEFT EQU 0                  ; 2048 float decode-history samples
PP_RIGHT EQU 8                 ; required only for channels=2
PP_WORK EQU 16                 ; separate caller-owned workspace
PP_CHANNELS EQU 24
PP_INPUT_CAP EQU 28            ; floats per input plane, >=2048
PP_WORK_CAP EQU 32             ; bytes, >=12816
PP_SIZE EQU 12816
PW_LP EQU 0                    ; 1024 floats
PW_AC EQU 4096                 ; 5 floats
PW_LPC EQU 4128                ; 4 floats
PW_MEM EQU 4160                ; 4 floats
PW_AC_SCRATCH EQU 4192          ; 1024 floats
PW_X4 EQU 8288                 ; 332 floats
PW_Y4 EQU 9616                 ; 487 floats
PW_CORR EQU 11568              ; 310 floats
