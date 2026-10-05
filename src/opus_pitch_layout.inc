# Fixed standard-mode CELT PLC pitch search request, 40 bytes.
.equ PP_LEFT, 0                  # 2048 float decode-history samples
.equ PP_RIGHT, 8                 # required only for channels=2
.equ PP_WORK, 16                 # separate caller-owned workspace
.equ PP_CHANNELS, 24
.equ PP_INPUT_CAP, 28            # floats per input plane, >=2048
.equ PP_WORK_CAP, 32             # bytes, >=12816
.equ PP_SIZE, 12816
.equ PW_LP, 0                    # 1024 floats
.equ PW_AC, 4096                 # 5 floats
.equ PW_LPC, 4128                # 4 floats
.equ PW_MEM, 4160                # 4 floats
.equ PW_AC_SCRATCH, 4192          # 1024 floats
.equ PW_X4, 8288                 # 332 floats
.equ PW_Y4, 9616                 # 487 floats
.equ PW_CORR, 11568              # 310 floats
