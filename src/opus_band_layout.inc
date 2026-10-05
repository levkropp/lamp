# Normal 48 kHz CELT mode band request, 112 bytes. All buffers are caller owned.
# X/Y, lowband, lowband_out and scratch each hold N floats when non-null.
# Public calls start at level zero; recursive calls are internal.
.equ OB_EC, 0
.equ OB_X, 8
.equ OB_Y, 16
.equ OB_LOW, 24
.equ OB_OUT, 32
.equ OB_REMAIN, 40
.equ OB_SEED, 48
.equ OB_SCRATCH, 56
.equ OB_N, 64
.equ OB_BUDGET, 68
.equ OB_BAND, 72
.equ OB_LM, 76
.equ OB_SPREAD, 80
.equ OB_BLOCKS, 84
.equ OB_INTENSITY, 88
.equ OB_TF, 92
.equ OB_LEVEL, 96
.equ OB_FILL, 100
.equ OB_GAIN, 104
.equ OB_CM, 108
