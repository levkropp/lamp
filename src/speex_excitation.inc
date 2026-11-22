# Caller-owned pitch request/result, 80 bytes. Source/bit/job/output regions
# must be disjoint; spx_pitch_decode validates these ownership boundaries.
.equ SPXE_EXC, 0
.equ SPXE_OUT, 8
.equ SPXE_HISTORY, 16
.equ SPXE_SAMPLES, 20
.equ SPXE_START, 24
.equ SPXE_END, 28
.equ SPXE_KIND, 32                 # NB7/7=0, LBR5/7=1, VLBR5/0=2, forced=3
.equ SPXE_LOST, 36
.equ SPXE_OFFSET, 40
.equ SPXE_LAST_GAIN, 44
.equ SPXE_COEF, 48
.equ SPXE_CAPACITY, 52
.equ SPXE_PITCH, 56
.equ SPXE_GAINS, 60
.equ SPXE_GAIN_SUM, 72
.equ SPXE_RESERVED, 76
.equ SPXE_SIZE, 80
