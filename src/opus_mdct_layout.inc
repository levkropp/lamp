# IMDCT request, 48 bytes; scalar float capacities.
.equ OM_IN, 0
.equ OM_OUT, 8
.equ OM_SCRATCH, 16
.equ OM_LM, 24
.equ OM_STRIDE, 28
.equ OM_IN_CAP, 32
.equ OM_OUT_CAP, 36
.equ OM_SCRATCH_CAP, 40
# Complete inverse-transform/overlap request, 64 bytes; planar float buffers.
.equ OY_FREQ, 0
.equ OY_OUT, 8
.equ OY_OVERLAP, 16
.equ OY_SCRATCH, 24
.equ OY_CHANNELS, 32
.equ OY_LM, 36
.equ OY_SHORT, 40
.equ OY_FREQ_CAP, 44
.equ OY_OUT_CAP, 48
.equ OY_OVERLAP_CAP, 52
.equ OY_SCRATCH_CAP, 56
