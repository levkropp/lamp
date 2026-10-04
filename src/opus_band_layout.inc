; Normal 48 kHz CELT mode band request, 112 bytes. All buffers are caller owned.
; X/Y, lowband, lowband_out and scratch each hold N floats when non-null.
; Public calls start at level zero; recursive calls are internal.
OB_EC EQU 0
OB_X EQU 8
OB_Y EQU 16
OB_LOW EQU 24
OB_OUT EQU 32
OB_REMAIN EQU 40
OB_SEED EQU 48
OB_SCRATCH EQU 56
OB_N EQU 64
OB_BUDGET EQU 68
OB_BAND EQU 72
OB_LM EQU 76
OB_SPREAD EQU 80
OB_BLOCKS EQU 84
OB_INTENSITY EQU 88
OB_TF EQU 92
OB_LEVEL EQU 96
OB_FILL EQU 100
OB_GAIN EQU 104
OB_CM EQU 108
