# Comb-filter request, 64 bytes; X starts at buffer+history floats.
.equ OF_BUFFER, 0
.equ OF_OUT, 8
.equ OF_N, 16
.equ OF_HISTORY, 20
.equ OF_PERIOD0, 24
.equ OF_PERIOD1, 28
.equ OF_GAIN0, 32
.equ OF_GAIN1, 36
.equ OF_TAP0, 40
.equ OF_TAP1, 44
.equ OF_OVERLAP, 48
.equ OF_BUFFER_CAP, 52
.equ OF_OUT_CAP, 56
# Deemphasis request, 48 bytes; planar X -> interleaved float PCM.
.equ OE_X, 0
.equ OE_PCM, 8
.equ OE_MEM, 16
.equ OE_N, 24
.equ OE_CHANNELS, 28
.equ OE_DOWNSAMPLE, 32
.equ OE_X_CAP, 36
.equ OE_PCM_CAP, 40
.equ OE_MEM_CAP, 44
